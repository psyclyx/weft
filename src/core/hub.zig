//! The collaboration hub: accept N peers on a listener and serve them
//! shared documents, as a background-accept thread + per-peer session.
//! Extracted from the headless host so the windowed editor can host too
//! (design rev 2: weft IS the peer; there is no dedicated agent).
//!
//! The hub is doc-policy-free. It owns only peer lifecycle — the
//! listener, the async accept loop, and each peer's Session/Conn — and a
//! generic, per-document presence relay. WHAT to bind on a new peer
//! (the primary document, presence layers, blob/diagnostics, late-joiner
//! share replay) is a caller-supplied `configure` callback, so headless
//! and the GUI share one implementation and differ only there.
//!
//! Threads never touch the frame loop: `acceptMain` blocks on `accept4`
//! and pushes fds onto a lock-free stack; the caller drains them each
//! frame in `acceptPending`. `stopAccepting` closes the listener (making
//! the in-flight accept error out) and joins — the one thing the
//! headless loop never needed, since it relied on process death.

const std = @import("std");
const Allocator = std.mem.Allocator;

const session = @import("session.zig");
const layers = @import("layers.zig");
const identity = @import("identity.zig");
const Document = @import("Document.zig");
const scheduler = @import("scheduler.zig");

const FdNode = struct { next: ?*FdNode = null, fd: i32 };

/// Relay closure payload for one (peer, document): identifies which
/// peer's presence NOT to echo back, and which document to route on.
/// Owned by the peer (freed with it).
pub const RelayCtx = struct {
    hub: *Hub,
    self_peer: *Peer,
    doc: *Document,
};

pub const Peer = struct {
    hub: *Hub,
    fd_link: session.FdLink,
    sess: *session.Session,
    conn: session.Conn,
    /// Set once this peer's identity (fingerprint + SAS + trust) has been
    /// noted to the store/log — the handshake completes asynchronously, so
    /// the host checks each tick until the fingerprint is available.
    identity_noted: bool = false,
    /// Set once a per-fingerprint grade override has been applied (also
    /// post-handshake, when the fingerprint is first known).
    graded: bool = false,
    /// One RelayCtx per bound document (owned).
    relays: std.ArrayList(*RelayCtx) = .empty,

    /// Allocate (and own) a relay context for a collab on `doc`. Assign
    /// the result to that collab's `relay_ctx`.
    pub fn relayFor(self: *Peer, doc: *Document) !*RelayCtx {
        const rc = try self.hub.gpa.create(RelayCtx);
        rc.* = .{ .hub = self.hub, .self_peer = self, .doc = doc };
        errdefer self.hub.gpa.destroy(rc);
        try self.relays.append(self.hub.gpa, rc);
        return rc;
    }
};

pub const Hub = struct {
    gpa: Allocator,
    token: []u8,
    /// Access grade granted to every peer that connects to this endpoint.
    access: session.Access = .view,
    /// This host's long-term identity, presented to every peer that joins
    /// (so they can name/verify us). Null → each peer session mints an
    /// ephemeral identity, as in tests.
    id: ?identity.Identity = null,
    /// Per-fingerprint access overrides. A peer whose fingerprint is here
    /// gets this grade instead of the endpoint default (`access`) — the
    /// authorization-by-identity seam. Applied on handshake completion and
    /// live via `setPeerAccess`.
    overrides: std.AutoHashMapUnmanaged([24]u8, session.Access) = .empty,
    clients: std.ArrayList(*Peer) = .empty,
    incoming: std.atomic.Value(?*FdNode) = .init(null),
    listener: ?i32 = null,
    accept_thread: ?std.Thread = null,
    /// Scheduler wake-fd (north-star-plan §6 W2a-3): signaled by the accept
    /// thread on a new incoming connection and by every peer's reader
    /// thread on new inbox data (`Session.wake_fd`, set on each peer at
    /// `adopt`) — ONE fd shared across N peers (an eventfd counter tolerates
    /// concurrent writers fine). The caller registers it as a scheduler fd
    /// source for the hub's lifetime.
    wake_fd: std.posix.fd_t,

    /// A hub with no listener yet — call `listen` once it is stored at a
    /// stable address (the accept thread captures `self`). `access` is the
    /// grade every peer on this endpoint is granted (safe default: view);
    /// `id` is the host identity presented to peers (null in tests).
    pub fn init(gpa: Allocator, token: []const u8, access: session.Access, id: ?*const identity.Identity) !Hub {
        const tok = try gpa.dupe(u8, token);
        errdefer gpa.free(tok);
        const wake_fd = try scheduler.newWakeFd();
        return .{
            .gpa = gpa,
            .token = tok,
            .access = access,
            .id = if (id) |i| i.* else null,
            .wake_fd = wake_fd,
        };
    }

    /// Bind the port and start accepting (non-blocking: bind/listen are
    /// immediate; `accept4` runs on the spawned thread). `self` must not
    /// move afterward.
    pub fn listen(self: *Hub, port: u16) !void {
        const l = try session.tcpListener(port);
        errdefer _ = std.os.linux.close(l);
        self.listener = l;
        self.accept_thread = try std.Thread.spawn(.{}, acceptMain, .{self});
    }

    /// Stop taking new peers (close the listener, join the accept
    /// thread); existing peers stay connected and keep syncing.
    pub fn stopAccepting(self: *Hub) void {
        if (self.listener) |l| {
            _ = std.os.linux.close(l);
            self.listener = null;
        }
        if (self.accept_thread) |th| {
            th.join();
            self.accept_thread = null;
        }
    }

    pub fn deinit(self: *Hub) void {
        self.stopAccepting();
        self.overrides.deinit(self.gpa);
        for (self.clients.items) |p| destroyPeer(self.gpa, p);
        self.clients.deinit(self.gpa);
        var cur = self.incoming.swap(null, .acquire);
        while (cur) |n| {
            cur = n.next;
            _ = std.os.linux.close(n.fd);
            self.gpa.destroy(n);
        }
        self.gpa.free(self.token);
        scheduler.closeWakeFd(self.wake_fd);
    }

    /// Adopt every fd the accept thread has queued, running `configure`
    /// to bind documents on each. A peer whose `configure` fails is
    /// dropped. Call once per frame.
    pub fn acceptPending(
        self: *Hub,
        ctx: ?*anyopaque,
        configure: *const fn (?*anyopaque, *Peer) anyerror!void,
    ) void {
        var pending = self.incoming.swap(null, .acquire);
        while (pending) |node| {
            pending = node.next;
            const fd = node.fd;
            self.gpa.destroy(node);
            const peer = self.adopt(fd) catch |err| {
                std.log.warn("hub: peer setup failed: {t}", .{err});
                continue;
            };
            configure(ctx, peer) catch |err| {
                std.log.warn("hub: peer configure failed: {t}", .{err});
                self.remove(self.clients.items.len - 1); // the just-added peer
            };
        }
    }

    /// Apply per-fingerprint grade overrides to peers whose handshake has
    /// just completed (the default grade was set at Session.create; this
    /// only moves the ones with an override). Idempotent per peer.
    fn applyGrades(self: *Hub) void {
        if (self.overrides.count() == 0) return;
        for (self.clients.items) |p| {
            if (p.graded) continue;
            const fp = p.sess.peerFingerprint() orelse continue;
            p.graded = true;
            if (self.overrides.get(fp)) |grade| p.sess.access = grade;
        }
    }

    /// Set a peer's grade by fingerprint: remembered for future connects
    /// and applied immediately to any live peer with that identity. This
    /// is authorization keyed by identity, not endpoint.
    pub fn setPeerAccess(self: *Hub, fp: [24]u8, grade: session.Access) !void {
        try self.overrides.put(self.gpa, fp, grade);
        for (self.clients.items) |p| {
            const pfp = p.sess.peerFingerprint() orelse continue;
            if (std.mem.eql(u8, &pfp, &fp)) p.sess.access = grade;
        }
    }

    /// Tick every peer; reap those gone offline. Returns whether any
    /// peer changed a document (→ repaint).
    pub fn tick(self: *Hub) bool {
        self.applyGrades();
        var changed = false;
        var i: usize = 0;
        while (i < self.clients.items.len) {
            const p = self.clients.items[i];
            changed = (p.conn.tick() catch false) or changed;
            if (p.sess.liveness() == .offline) {
                std.log.info("hub: peer departed ({d} left)", .{self.clients.items.len - 1});
                self.remove(i);
            } else i += 1;
        }
        return changed;
    }

    fn adopt(self: *Hub, fd: i32) !*Peer {
        const gpa = self.gpa;
        const p = try gpa.create(Peer);
        errdefer gpa.destroy(p);
        p.* = .{ .hub = self, .fd_link = .{ .fd = fd }, .sess = undefined, .conn = undefined };
        p.sess = try session.Session.create(gpa, p.fd_link.link(), .server, self.token, self.access, if (self.id) |*i| i else null);
        errdefer p.sess.destroy();
        p.sess.setWakeFd(self.wake_fd);
        p.conn = try session.Conn.init(gpa, p.sess, "host", .server);
        errdefer p.conn.deinit();
        try self.clients.append(gpa, p);
        std.log.info("hub: peer joined ({d} connected)", .{self.clients.items.len});
        return p;
    }

    pub fn remove(self: *Hub, i: usize) void {
        destroyPeer(self.gpa, self.clients.swapRemove(i));
    }

    fn destroyPeer(gpa: Allocator, p: *Peer) void {
        p.conn.deinit();
        p.sess.destroy();
        for (p.relays.items) |rc| gpa.destroy(rc);
        p.relays.deinit(gpa);
        gpa.destroy(p);
    }
};

fn acceptMain(hub: *Hub) void {
    const listener = hub.listener orelse return;
    while (true) {
        const fd = session.tcpAccept(listener) catch return; // listener closed → stop
        const node = hub.gpa.create(FdNode) catch {
            _ = std.os.linux.close(fd);
            continue;
        };
        node.* = .{ .fd = fd };
        var head = hub.incoming.load(.monotonic);
        while (true) {
            node.next = head;
            head = hub.incoming.cmpxchgWeak(head, node, .release, .monotonic) orelse break;
        }
        scheduler.signalWakeFd(hub.wake_fd);
    }
}

/// Presence relay: forward one peer's cursor to every OTHER peer's
/// collab on the same document (its presence channel, `base + 1`).
/// `ctx` is a `*RelayCtx`. Doc-aware, so it is correct whether or not
/// bases coincide across peers.
pub fn relayPresence(ctx: ?*anyopaque, key: u64, payload: []const u8) void {
    const rc: *RelayCtx = @ptrCast(@alignCast(ctx.?));
    for (rc.hub.clients.items) |peer| {
        if (peer == rc.self_peer) continue;
        for (peer.conn.collabs.items) |col| {
            if (col.doc == rc.doc) {
                peer.sess.postFeed(col.base + 1, key, payload) catch {};
                break;
            }
        }
    }
}

/// Union every peer's cursor on `doc` into one presence `layer` — the
/// local display for a hub that is ALSO a participant (per-peer collabs
/// keep `presence_layer = null` so they don't clobber each other; this
/// merges their sets). Dedups by peer name (last wins).
pub fn unionPresence(self: *Hub, doc: *Document, layer: *layers.Layer, gpa: Allocator) !void {
    var spans: std.ArrayList(layers.SpanIn) = .empty;
    defer spans.deinit(gpa);
    for (self.clients.items) |peer| {
        for (peer.conn.collabs.items) |col| {
            if (col.doc != doc) continue;
            for (col.presence.items) |*presence| {
                const resolved = col.resolvePresence(presence) orelse continue;
                var dup = false;
                for (spans.items) |s| {
                    if (std.mem.eql(u8, s.message, resolved.name)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                try spans.append(gpa, .{
                    .start = @min(resolved.head, resolved.selection_anchor),
                    .end = @max(resolved.head, resolved.selection_anchor),
                    .kind = session.Collab.packPresenceKind(resolved.hue16, resolved.head <= resolved.selection_anchor),
                    .message = resolved.name,
                });
            }
        }
    }
    try layer.publishSpans(gpa, spans.items);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;
const linux = std.os.linux;

fn socketPair() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
    if (linux.errno(rc) != .SUCCESS) return error.SocketPair;
    return fds;
}

fn park(ms: u64) void {
    var w: std.atomic.Value(u32) = .init(0);
    var ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.futex_4arg(&w.raw, .{ .cmd = .WAIT, .private = true }, 0, &ts);
}

// A hub-that-is-also-a-participant: two peers on one primary document.
// Ops converge across both; presence is relayed between peers AND
// merged locally by unionPresence. Drives adopt/relayFor/relayPresence/
// unionPresence directly over socketpairs (no accept thread).
test "hub: two peers converge; presence relays and unions" {
    const gpa = t.allocator;
    var doc_p = try Document.init(gpa, "host");
    defer doc_p.deinit(gpa);
    var doc_a = try Document.init(gpa, "alice");
    defer doc_a.deinit(gpa);
    var doc_b = try Document.init(gpa, "bob");
    defer doc_b.deinit(gpa);
    // Declared after the docs so its deinit (which removes anchors from
    // them) runs BEFORE they are torn down.
    var store: layers.Layers = .empty;
    defer store.deinit(gpa);
    try doc_p.insert(gpa, 0, "base\n");

    var hub = try Hub.init(gpa, "tok", .edit, null);
    defer hub.deinit();

    const pa = try socketPair();
    const pb = try socketPair();
    const peer_a = try hub.adopt(pa[0]);
    const peer_b = try hub.adopt(pb[0]);
    inline for (.{ peer_a, peer_b }) |peer| {
        const col = try peer.conn.bindPrimary(&doc_p, 1);
        col.presence_layer = null;
        col.publish_presence = true;
        col.relay = relayPresence;
        col.relay_ctx = try peer.relayFor(&doc_p);
    }

    var la: session.FdLink = .{ .fd = pa[1] };
    var lb: session.FdLink = .{ .fd = pb[1] };
    var sa = try session.Session.create(gpa, la.link(), .client, "tok", .own, null);
    defer sa.destroy();
    var sb = try session.Session.create(gpa, lb.link(), .client, "tok", .own, null);
    defer sb.destroy();
    var ca = try session.Collab.init(gpa, sa, &doc_a, "alice");
    defer ca.deinit();
    var cb = try session.Collab.init(gpa, sb, &doc_b, "bob");
    defer cb.deinit();
    ca.presence_layer = try store.claim(gpa, &doc_a, "presence", .replicated, "collab");
    cb.presence_layer = try store.claim(gpa, &doc_b, "presence", .replicated, "collab");
    // Both peers select cursor sharing.
    ca.publish_presence = true;
    cb.publish_presence = true;

    try doc_a.insert(gpa, 0, "A! ");
    try doc_b.insert(gpa, 0, "B! ");

    // Converge all three documents.
    var rounds: usize = 0;
    const converged = while (rounds < 1500) : (rounds += 1) {
        _ = hub.tick();
        _ = try ca.tick(5);
        _ = try cb.tick(9);
        const ta = try doc_a.text().toOwnedSlice(gpa);
        defer gpa.free(ta);
        const tb = try doc_b.text().toOwnedSlice(gpa);
        defer gpa.free(tb);
        const tp = try doc_p.text().toOwnedSlice(gpa);
        defer gpa.free(tp);
        if (std.mem.eql(u8, ta, tb) and std.mem.eql(u8, tb, tp) and
            std.mem.indexOf(u8, tp, "A!") != null and std.mem.indexOf(u8, tp, "B!") != null and
            std.mem.indexOf(u8, tp, "base") != null) break true;
        park(1);
    } else false;
    try t.expect(converged);

    // A few more rounds so presence feeds settle both ways.
    for (0..400) |_| {
        _ = hub.tick();
        _ = try ca.tick(5);
        _ = try cb.tick(9);
        park(1);
    }

    // unionPresence merges both peers' cursors onto the primary.
    const union_layer = try store.claim(gpa, &doc_p, "presence", .replicated, "hub");
    try unionPresence(&hub, &doc_p, union_layer, gpa);
    var saw_a = false;
    var saw_b = false;
    for (0..union_layer.spanCount()) |i| {
        const m = union_layer.resolvedSpan(i).message;
        if (std.mem.eql(u8, m, "alice")) saw_a = true;
        if (std.mem.eql(u8, m, "bob")) saw_b = true;
    }
    try t.expect(saw_a and saw_b);

    // Relay: bob's client sees alice's cursor (and vice versa).
    var bob_saw_alice = false;
    for (0..cb.presence_layer.?.spanCount()) |i| {
        if (std.mem.eql(u8, cb.presence_layer.?.resolvedSpan(i).message, "alice")) bob_saw_alice = true;
    }
    try t.expect(bob_saw_alice);
}

test "hub: a per-fingerprint grant elevates a peer from view to edit" {
    const gpa = t.allocator;
    var doc_h = try Document.init(gpa, "host");
    defer doc_h.deinit(gpa);
    var doc_c = try Document.init(gpa, "client");
    defer doc_c.deinit(gpa);
    try doc_h.insert(gpa, 0, "base\n");

    // Endpoint default is view (safe); the peer starts read-only.
    var hub = try Hub.init(gpa, "tok", .view, null);
    defer hub.deinit();

    const pair = try socketPair();
    const peer = try hub.adopt(pair[0]);
    _ = try peer.conn.bindPrimary(&doc_h, 1);

    const id_client = identity.Identity.forTest(0x5c);
    var lc: session.FdLink = .{ .fd = pair[1] };
    const sc = try session.Session.create(gpa, lc.link(), .client, "tok", .own, &id_client);
    defer sc.destroy();
    var cc = try session.Collab.init(gpa, sc, &doc_c, "client");
    defer cc.deinit();

    const H = struct {
        fn until(h: *Hub, c: *session.Collab, doc: *Document, needle: []const u8, a: Allocator) !bool {
            var round: usize = 0;
            while (round < 4000) : (round += 1) {
                _ = h.tick();
                _ = try c.tick(0);
                const txt = try doc.text().toOwnedSlice(a);
                defer a.free(txt);
                if (std.mem.indexOf(u8, txt, needle) != null) return true;
                park(1);
            }
            return false;
        }
    };

    // Link is live: the host's base reaches the client.
    try t.expect(try H.until(&hub, &cc, &doc_c, "base", gpa));

    // While view-only, the client's edit is dropped by the host.
    try doc_c.insert(gpa, doc_c.text().byteLen(), "VIEW");
    for (0..300) |_| {
        _ = hub.tick();
        _ = try cc.tick(0);
        park(1);
    }
    {
        const th = try doc_h.text().toOwnedSlice(gpa);
        defer gpa.free(th);
        try t.expect(std.mem.indexOf(u8, th, "VIEW") == null);
    }

    // Grant edit to the client's fingerprint; now its edits land.
    try hub.setPeerAccess(id_client.fingerprint(), .edit);
    try doc_c.insert(gpa, doc_c.text().byteLen(), "EDIT");
    try t.expect(try H.until(&hub, &cc, &doc_h, "EDIT", gpa));
}

test "hub: the host's granted grade reaches the client as my_grant" {
    const gpa = t.allocator;
    var doc_h = try Document.init(gpa, "host");
    defer doc_h.deinit(gpa);
    var doc_c = try Document.init(gpa, "client");
    defer doc_c.deinit(gpa);
    try doc_h.insert(gpa, 0, "base\n");

    // Safe endpoint default: a fresh peer is a viewer until granted more.
    var hub = try Hub.init(gpa, "tok", .view, null);
    defer hub.deinit();

    const pair = try socketPair();
    const peer = try hub.adopt(pair[0]);
    _ = try peer.conn.bindPrimary(&doc_h, 1);

    const id_client = identity.Identity.forTest(0x5c);
    var lc: session.FdLink = .{ .fd = pair[1] };
    const sc = try session.Session.create(gpa, lc.link(), .client, "tok", .own, &id_client);
    defer sc.destroy();
    var cc = try session.Collab.init(gpa, sc, &doc_c, "client");
    defer cc.deinit();

    const H = struct {
        fn untilGrant(h: *Hub, c: *session.Collab, doc: *Document, want: session.Access) !bool {
            var round: usize = 0;
            while (round < 4000) : (round += 1) {
                _ = h.tick();
                _ = try c.tick(0);
                if (doc.my_grant == want) return true;
                park(1);
            }
            return false;
        }
    };

    // On connect the host announces the endpoint default (view) — the
    // client now KNOWS it is read-only and can refuse a local ghost.
    try t.expect(try H.untilGrant(&hub, &cc, &doc_c, .view));
    // A live elevation propagates to the client…
    try hub.setPeerAccess(id_client.fingerprint(), .edit);
    try t.expect(try H.untilGrant(&hub, &cc, &doc_c, .edit));
    // …and so does a downgrade.
    try hub.setPeerAccess(id_client.fingerprint(), .view);
    try t.expect(try H.untilGrant(&hub, &cc, &doc_c, .view));
}

test {
    std.testing.refAllDecls(@This());
}
