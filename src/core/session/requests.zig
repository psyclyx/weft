//! Requester side of wire class 2 (doc/wire.md): client-generated u64 ids,
//! each with a deadline. A reply that is lost — dropped frame, a peer that
//! cannot serve the call, a link that dies mid-flight — settles as an
//! explicit failure when the deadline passes, never as an unbounded wait.
//! Retrying, if it makes sense at all, is the caller's policy.

const std = @import("std");
const Allocator = std.mem.Allocator;

const wire = @import("weft_wire");
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

/// One whole requester: ids under deadlines (`Inflight`) plus the answers
/// that landed and have not been taken. `call_kind` — which `RequestKind`
/// its calls ride — is the ONLY thing that differs between the cycles on a
/// quad's request channel (`.fs_call` for the `.peer` filesystem,
/// `.lsp_call` for the typed language service), so it is the only parameter.
/// Async by construction: nothing here blocks a frame thread.
///
/// `session` is duck-typed (`liveness()` + `post()`) so this file stays free
/// of the transport it posts through.
pub fn Requester(comptime call_kind: wire.RequestKind) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        inflight: Inflight(void) = .{},
        /// Settled calls by id, until the caller takes them.
        settled: std.AutoHashMapUnmanaged(u64, Outcome) = .empty,

        /// What a call came back as: the peer's response bytes, or the peer
        /// saying it could not serve it, and why.
        const Outcome = union(enum) { reply: []u8, failed: wire.FailureReason };

        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            var it = self.settled.valueIterator();
            while (it.next()) |v| switch (v.*) {
                .reply => |bytes| self.gpa.free(bytes),
                .failed => {},
            };
            self.settled.deinit(self.gpa);
            self.inflight.deinit(self.gpa);
        }

        /// How long a call waits for its reply before `take` fails it.
        pub fn setTimeout(self: *Self, ns: u64) void {
            self.inflight.timeout_ns = ns;
        }

        /// Post an encoded request on `base+3`; returns the call id the
        /// reply will mirror.
        ///
        /// An offline peer refuses here, at once
        /// (doc/contextual-workspace-architecture.md §13.7: "remote mutation
        /// actions are never automatically queued"). Enqueuing would put a
        /// mutation in a buffer whose only honest fates are a silent drop or
        /// a replay the owner never authorized; the caller gets a reason it
        /// can show instead of a deadline it must sit out.
        pub fn request(self: *Self, session: anytype, base: u64, req: []const u8) !u64 {
            if (session.liveness() == .offline) return error.PeerOffline;
            const id = try self.inflight.issue(self.gpa, {});
            var p: std.ArrayList(u8) = .empty;
            defer p.deinit(self.gpa);
            try wire.putUv(self.gpa, &p, id);
            try p.appendSlice(self.gpa, req);
            try session.post(.request, @intFromEnum(call_kind), base + 3, p.items);
            return id;
        }

        /// A reply frame arrived (`uv id | response`): store it by id.
        pub fn onReply(self: *Self, gpa: Allocator, payload: []const u8) !void {
            var cur: []const u8 = payload;
            const id = wire.getUv(&cur) catch return;
            const owned = try gpa.dupe(u8, cur);
            errdefer gpa.free(owned);
            try self.put(gpa, id, .{ .reply = owned });
        }

        /// The peer cannot serve `id` (an `*_err` frame), for `reason`. The
        /// caller takes the failure now rather than waiting out its deadline.
        pub fn onFailure(self: *Self, gpa: Allocator, id: u64, reason: wire.FailureReason) void {
            self.put(gpa, id, .{ .failed = reason }) catch {};
        }

        fn put(self: *Self, gpa: Allocator, id: u64, outcome: Outcome) !void {
            const gop = try self.settled.getOrPut(gpa, id);
            if (gop.found_existing) switch (gop.value_ptr.*) {
                .reply => |bytes| gpa.free(bytes),
                .failed => {},
            };
            gop.value_ptr.* = outcome;
            _ = self.inflight.settle(id);
        }

        /// Take the completed response for `id` (owned; caller frees), or
        /// null while it is still in flight. A peer that refused the call,
        /// and a deadline that passed, are errors — never an endless wait. A
        /// refusal the peer attributed to a missing grant surfaces as
        /// `RequestDenied`, so a caller can say "not granted" rather than
        /// "something failed".
        pub fn take(self: *Self, id: u64) Error!?[]u8 {
            if (self.settled.fetchRemove(id)) |kv| switch (kv.value) {
                .reply => |bytes| return bytes,
                .failed => |reason| return switch (reason) {
                    .not_granted => error.RequestDenied,
                    else => error.RequestFailed,
                },
            };
            if (self.inflight.timedOut(id, task.nowNs())) return error.RequestTimeout;
            return null;
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
