//! The platform half of the system clipboard (doc/configs.md §3.3): the text
//! the desktop last put on the clipboard, and the pipe transfers that move it.
//!
//! A clipboard is a PROTOCOL between clients, and every transfer is a pipe the
//! other client reads or writes at its own pace. None of it may block the
//! frame loop: a paste from a hung client must not freeze the editor, and a
//! copy of a big buffer must not stall a frame while the other side reads it.
//! So every transfer here is non-blocking and parked in ONE epoll set, whose
//! fd the shell registers with the scheduler once (`app/loop_sources.zig`
//! style — `Window.clipboardFd`). The platform's `pumpEvents` calls `service`
//! on every wake, which moves whatever bytes are ready and finishes whatever
//! transfers are done.
//!
//! Reads are EAGER: a platform starts reading an offer the moment the desktop
//! announces it, so `Store.text` is what the user last copied by the time a
//! paste asks, with no request/response for a guest to wait on. The cost is
//! reading copies nobody pastes, which is a pipe of text.
//!
//! Platform-neutral (Linux fds, no Wayland): `wayland.zig` is the protocol
//! glue, and a headless platform uses `Store` alone — the in-memory clipboard.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

/// The clipboard's last-known text: what this client set, or what it last
/// received from another. The whole clipboard for a platform with no desktop.
pub const Store = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// Bumped by every `set`. A receive remembers the value it started at
    /// and lands only if nothing set the store since: a copy made here while
    /// an older foreign offer was still being read is newer than that offer,
    /// whichever finishes first (`Transfers.receive`).
    gen: u64 = 0,

    pub fn deinit(self: *Store, gpa: Allocator) void {
        self.bytes.deinit(gpa);
        self.* = .{};
    }

    pub fn text(self: *const Store) []const u8 {
        return self.bytes.items;
    }

    pub fn set(self: *Store, gpa: Allocator, bytes: []const u8) Allocator.Error!void {
        self.gen += 1;
        self.bytes.clearRetainingCapacity();
        try self.bytes.appendSlice(gpa, bytes);
    }
};

/// Every clipboard pipe in flight, behind one epoll fd.
pub const Transfers = struct {
    /// How many outgoing transfers may be in flight at once. Each is one
    /// client pasting from us; past this, the oldest is dropped (its reader
    /// sees EOF early) rather than letting a stuck reader pin memory forever.
    pub const max_outgoing = 8;
    /// The most an incoming offer may hold. Another client decides how much
    /// it writes; past this the offer is dropped (with a warning) rather than
    /// growing the buffer without bound.
    pub const max_incoming = 16 * 1024 * 1024;

    /// `since` is the store generation the receive started at.
    const Incoming = struct { fd: i32, since: u64, buf: std.ArrayList(u8) = .empty };
    const Outgoing = struct { fd: i32, bytes: []u8, off: usize = 0 };

    epfd: i32,
    incoming: ?Incoming = null,
    outgoing: [max_outgoing]?Outgoing = @splat(null),

    pub fn init() !Transfers {
        const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.EpollCreateFailed;
        return .{ .epfd = @intCast(rc) };
    }

    pub fn deinit(self: *Transfers, gpa: Allocator) void {
        self.abortIncoming(gpa);
        for (&self.outgoing) |*o| self.finishOutgoing(gpa, o);
        _ = linux.close(self.epfd);
        self.* = undefined;
    }

    /// Readable whenever any transfer can make progress.
    pub fn fd(self: *const Transfers) i32 {
        return self.epfd;
    }

    /// Whether an offer is still being read.
    pub fn receiving(self: *const Transfers) bool {
        return self.incoming != null;
    }

    /// Start reading the selection from `read_fd` (owned from here on) into
    /// `store`. A receive already in flight is abandoned: the desktop has
    /// moved on to a newer selection, and only the newest one is the
    /// clipboard. So is this one if `store` is set before it finishes.
    pub fn receive(self: *Transfers, gpa: Allocator, store: *const Store, read_fd: i32) void {
        self.abortIncoming(gpa);
        if (!setNonblocking(read_fd) or !self.watch(read_fd, linux.EPOLL.IN)) {
            _ = linux.close(read_fd);
            return;
        }
        self.incoming = .{ .fd = read_fd, .since = store.gen };
    }

    /// Start writing `bytes` (copied) to `write_fd` (owned from here on).
    /// Writes what fits now; the rest follows as the reader drains.
    pub fn send(self: *Transfers, gpa: Allocator, write_fd: i32, bytes: []const u8) void {
        const copy = gpa.dupe(u8, bytes) catch {
            _ = linux.close(write_fd);
            return;
        };
        const slot = for (&self.outgoing) |*o| {
            if (o.* == null) break o;
        } else blk: {
            self.finishOutgoing(gpa, &self.outgoing[0]);
            break :blk &self.outgoing[0];
        };
        if (!setNonblocking(write_fd) or !self.watch(write_fd, linux.EPOLL.OUT)) {
            gpa.free(copy);
            _ = linux.close(write_fd);
            return;
        }
        slot.* = .{ .fd = write_fd, .bytes = copy };
        self.pumpOutgoing(gpa, slot);
    }

    /// Move every ready byte; finish what is done. A finished receive
    /// replaces `store`'s text and answers true, so the caller knows the
    /// clipboard changed. Never blocks.
    pub fn service(self: *Transfers, gpa: Allocator, store: *Store) bool {
        // The epoll set is only the WAKE: draining it here keeps a level-
        // triggered fd from waking the loop forever, and the transfers are
        // few enough to just try each one.
        var events: [max_outgoing + 1]linux.epoll_event = undefined;
        _ = linux.epoll_wait(self.epfd, &events, events.len, 0);
        for (&self.outgoing) |*o| if (o.* != null) self.pumpOutgoing(gpa, o);
        return self.pumpIncoming(gpa, store);
    }

    fn pumpIncoming(self: *Transfers, gpa: Allocator, store: *Store) bool {
        if (self.incoming == null) return false;
        // Superseded: we took the selection ourselves after this began.
        if (self.incoming.?.since != store.gen) {
            self.abortIncoming(gpa);
            return false;
        }
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            const inc = &self.incoming.?;
            const rc = linux.read(inc.fd, &chunk, chunk.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => return false,
                .INTR => continue,
                else => {
                    self.abortIncoming(gpa);
                    return false;
                },
            }
            if (rc == 0) {
                // EOF: the whole selection is here.
                store.set(gpa, inc.buf.items) catch {};
                self.abortIncoming(gpa);
                return true;
            }
            if (inc.buf.items.len + rc > max_incoming) {
                std.log.warn("clipboard: dropped an offer over {d} bytes", .{max_incoming});
                self.abortIncoming(gpa);
                return false;
            }
            inc.buf.appendSlice(gpa, chunk[0..rc]) catch {
                self.abortIncoming(gpa);
                return false;
            };
        }
    }

    fn pumpOutgoing(self: *Transfers, gpa: Allocator, slot: *?Outgoing) void {
        if (slot.* == null) return;
        const o = &slot.*.?;
        while (o.off < o.bytes.len) {
            const rc = linux.write(o.fd, o.bytes[o.off..].ptr, o.bytes.len - o.off);
            switch (linux.errno(rc)) {
                .SUCCESS => o.off += rc,
                .AGAIN => return,
                .INTR => continue,
                else => break, // the reader went away: nothing left to do
            }
        }
        self.finishOutgoing(gpa, slot);
    }

    fn abortIncoming(self: *Transfers, gpa: Allocator) void {
        var in = self.incoming orelse return;
        self.unwatch(in.fd);
        _ = linux.close(in.fd);
        in.buf.deinit(gpa);
        self.incoming = null;
    }

    fn finishOutgoing(self: *Transfers, gpa: Allocator, slot: *?Outgoing) void {
        const o = slot.* orelse return;
        self.unwatch(o.fd);
        _ = linux.close(o.fd);
        gpa.free(o.bytes);
        slot.* = null;
    }

    fn watch(self: *Transfers, target: i32, events: u32) bool {
        var ev: linux.epoll_event = .{ .events = events, .data = .{ .fd = target } };
        return linux.errno(linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, target, &ev)) == .SUCCESS;
    }

    fn unwatch(self: *Transfers, target: i32) void {
        _ = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_DEL, target, null);
    }
};

fn setNonblocking(target: i32) bool {
    const flags = linux.fcntl(target, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return false;
    const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    return linux.errno(linux.fcntl(target, linux.F.SETFL, flags | nonblock)) == .SUCCESS;
}

/// A pipe for a transfer: `[read, write]`, close-on-exec.
pub fn pipe() ?[2]i32 {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return null;
    return fds;
}

const t = std.testing;

test "clipboard: the store round-trips (the headless clipboard)" {
    var store: Store = .{};
    defer store.deinit(t.allocator);
    try t.expectEqualStrings("", store.text());
    try store.set(t.allocator, "copied");
    try t.expectEqualStrings("copied", store.text());
    try store.set(t.allocator, "again");
    try t.expectEqualStrings("again", store.text());
}

test "clipboard: a send and a receive meet through pipes without blocking" {
    const gpa = t.allocator;
    var xfers = try Transfers.init();
    defer xfers.deinit(gpa);
    var store: Store = .{};
    defer store.deinit(gpa);

    // Another client pastes from us: we write into its pipe…
    const out = pipe().?;
    xfers.send(gpa, out[1], "from weft");
    // …and one of ours reads the other client's copy.
    xfers.receive(gpa, &store, out[0]);
    try t.expect(xfers.receiving());
    // The write fit the pipe and closed, so the read sees the bytes and EOF.
    try t.expect(xfers.service(gpa, &store));
    try t.expectEqualStrings("from weft", store.text());
    try t.expect(!xfers.receiving());
}

test "clipboard: a receive with no writer yet waits instead of blocking" {
    const gpa = t.allocator;
    var xfers = try Transfers.init();
    defer xfers.deinit(gpa);
    var store: Store = .{};
    defer store.deinit(gpa);
    try store.set(gpa, "old");

    const p = pipe().?;
    xfers.receive(gpa, &store, p[0]);
    try t.expect(!xfers.service(gpa, &store)); // nothing written: AGAIN, not a hang
    try t.expectEqualStrings("old", store.text());
    _ = linux.write(p[1], "new", 3);
    try t.expect(!xfers.service(gpa, &store)); // bytes, but the writer is still open
    _ = linux.close(p[1]);
    try t.expect(xfers.service(gpa, &store));
    try t.expectEqualStrings("new", store.text());
}

test "clipboard: a newer selection abandons the read in flight" {
    const gpa = t.allocator;
    var xfers = try Transfers.init();
    defer xfers.deinit(gpa);
    var store: Store = .{};
    defer store.deinit(gpa);

    const first = pipe().?;
    xfers.receive(gpa, &store, first[0]);
    _ = linux.write(first[1], "stale", 5);
    const second = pipe().?;
    xfers.receive(gpa, &store, second[0]); // closes first[0]
    _ = linux.close(first[1]);
    _ = linux.write(second[1], "fresh", 5);
    _ = linux.close(second[1]);
    try t.expect(xfers.service(gpa, &store));
    try t.expectEqualStrings("fresh", store.text());
}

test "clipboard: a copy made here while a foreign offer is still being read wins, whichever finishes first" {
    const gpa = t.allocator;
    var xfers = try Transfers.init();
    defer xfers.deinit(gpa);
    var store: Store = .{};
    defer store.deinit(gpa);

    const p = pipe().?;
    xfers.receive(gpa, &store, p[0]);
    _ = linux.write(p[1], "foreign", 7);
    // We take the selection (a C-c) before the other client's pipe ends…
    try store.set(gpa, "ours");
    // …so its EOF must not put the older offer back over it.
    _ = linux.close(p[1]);
    try t.expect(!xfers.service(gpa, &store));
    try t.expectEqualStrings("ours", store.text());
    try t.expect(!xfers.receiving());
}

test "clipboard: an offer past the size cap is dropped, and the clipboard keeps what it had" {
    const gpa = t.allocator;
    var xfers = try Transfers.init();
    defer xfers.deinit(gpa);
    var store: Store = .{};
    defer store.deinit(gpa);
    try store.set(gpa, "kept");

    const p = pipe().?;
    xfers.receive(gpa, &store, p[0]);
    try t.expect(setNonblocking(p[1])); // a full pipe answers AGAIN, never blocks the test
    // Feed more than the cap, a pipe-full at a time, servicing between.
    const block: [64 * 1024]u8 = @splat('x');
    var sent: usize = 0;
    while (xfers.receiving() and sent <= Transfers.max_incoming + block.len) {
        const rc = linux.write(p[1], &block, block.len);
        if (linux.errno(rc) == .SUCCESS) sent += rc;
        _ = xfers.service(gpa, &store);
    }
    _ = linux.close(p[1]);
    try t.expect(!xfers.receiving());
    try t.expect(!xfers.service(gpa, &store));
    try t.expectEqualStrings("kept", store.text());
}
