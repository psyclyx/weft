//! Requester side of wire class 2 (doc/wire.md): client-generated u64 ids,
//! each with a deadline. A reply that is lost — dropped frame, a peer that
//! cannot serve the call, a link that dies mid-flight — settles as an
//! explicit failure when the deadline passes, never as an unbounded wait.
//! Retrying, if it makes sense at all, is the caller's policy.

const std = @import("std");
const Allocator = std.mem.Allocator;

const task = @import("../task.zig");

/// How long a request waits for its reply. Sized for a human-latency link
/// (tailnet/ssh), not for a benchmark; a caller that needs a tighter bound
/// sets its own.
pub const default_timeout_ns: u64 = 10 * std.time.ns_per_s;

/// Why no usable reply will come: the peer said so (an `err`/`fs_err`
/// frame), it said so because we hold no grant for that export surface, or
/// the deadline passed with nothing at all. A responder that names no reason
/// reads as `RequestFailed`, so an older peer degrades to the plain refusal.
pub const Error = error{ RequestFailed, RequestDenied, RequestTimeout };

/// The requests we are still waiting on, keyed by wire id. `Ctx` is what
/// the reply means to the requester (a byte span, a call kind, `void`).
pub fn Inflight(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct { ctx: Ctx, deadline_ns: u64 };
        pub const Expired = struct { id: u64, ctx: Ctx };

        next_id: u64 = 1,
        /// Default deadline for `issue`. A product knob — see the
        /// `setTimeout` wrappers on the requesters.
        timeout_ns: u64 = default_timeout_ns,
        entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.entries.deinit(gpa);
        }

        /// Reserve the next id and start its clock.
        pub fn issue(self: *Self, gpa: Allocator, ctx: Ctx) !u64 {
            return self.issueWithin(gpa, ctx, self.timeout_ns);
        }

        /// Same, under a deadline chosen for this one request.
        pub fn issueWithin(self: *Self, gpa: Allocator, ctx: Ctx, timeout_ns: u64) !u64 {
            const id = self.next_id;
            try self.entries.put(gpa, id, .{
                .ctx = ctx,
                .deadline_ns = task.nowNs() +| timeout_ns,
            });
            self.next_id += 1;
            return id;
        }

        /// Settle `id` and hand back its context; null when we are not
        /// waiting on it (a duplicate reply, or one already failed).
        pub fn settle(self: *Self, id: u64) ?Ctx {
            const kv = self.entries.fetchRemove(id) orelse return null;
            return kv.value.ctx;
        }

        /// Settle `id` as failed if its deadline has passed.
        pub fn timedOut(self: *Self, id: u64, now_ns: u64) bool {
            const entry = self.entries.get(id) orelse return false;
            if (now_ns < entry.deadline_ns) return false;
            _ = self.entries.remove(id);
            return true;
        }

        /// Settle and report one request past its deadline. Loop until
        /// null to fail them all.
        pub fn nextTimedOut(self: *Self, now_ns: u64) ?Expired {
            var it = self.entries.iterator();
            while (it.next()) |e| {
                if (now_ns < e.value_ptr.deadline_ns) continue;
                const expired: Expired = .{ .id = e.key_ptr.*, .ctx = e.value_ptr.ctx };
                _ = self.entries.remove(expired.id);
                return expired;
            }
            return null;
        }

        /// Every request still in flight — the "am I already asking for
        /// this?" scan.
        pub fn pending(self: *Self) std.AutoHashMapUnmanaged(u64, Entry).ValueIterator {
            return self.entries.valueIterator();
        }

        pub fn count(self: *const Self) usize {
            return self.entries.count();
        }
    };
}

const t = std.testing;

test "requests: a reply settles the id, a passed deadline fails it" {
    const gpa = t.allocator;
    var inflight: Inflight(u32) = .{};
    defer inflight.deinit(gpa);

    const answered = try inflight.issue(gpa, 7);
    const lost = try inflight.issueWithin(gpa, 9, 0); // already due
    try t.expectEqual(@as(u64, 1), answered);
    try t.expectEqual(@as(u64, 2), lost);

    try t.expectEqual(@as(?u32, 7), inflight.settle(answered));
    try t.expectEqual(@as(?u32, null), inflight.settle(answered)); // once only

    const now = task.nowNs();
    try t.expect(!inflight.timedOut(answered, now)); // settled, not pending
    const expired = inflight.nextTimedOut(now).?;
    try t.expectEqual(lost, expired.id);
    try t.expectEqual(@as(u32, 9), expired.ctx);
    try t.expectEqual(@as(?Inflight(u32).Expired, null), inflight.nextTimedOut(now));
    try t.expectEqual(@as(usize, 0), inflight.count());
}

test "requests: a live request neither settles nor expires" {
    const gpa = t.allocator;
    var inflight: Inflight(void) = .{};
    defer inflight.deinit(gpa);
    inflight.timeout_ns = std.time.ns_per_s;

    const id = try inflight.issue(gpa, {});
    const now = task.nowNs();
    try t.expect(!inflight.timedOut(id, now));
    try t.expectEqual(@as(?Inflight(void).Expired, null), inflight.nextTimedOut(now));
    try t.expectEqual(@as(usize, 1), inflight.count());
}
