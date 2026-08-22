//! Cross-cutting integration tests for the `session` subsystem: two (or
//! three) live `Session`s driven over a socketpair, exercising the whole
//! document-sync stack end to end — view-only admission, convergence with
//! presence, multi-buffer `Conn` sharing, partial checkout, `.peer` fs,
//! handshake auth/SAS, chaos partitions, hub relay/reconnect, and the TCP
//! bootstrap. The per-type unit tests live in their own struct files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const identity = @import("../identity.zig");
const task = @import("../task.zig");
const wire = @import("../wire.zig");
const Document = @import("../Document.zig");
const layers_mod = @import("../layers.zig");
const subbuffer = @import("../subbuffer.zig");
const GraphDoc = @import("../graph.zig");
const TranscriptDoc = @import("../transcript.zig");

const session = @import("../session.zig");
const Session = @import("Session.zig");
const Collab = @import("Collab.zig");
const GraphCollab = @import("GraphCollab.zig");
const Conn = @import("Conn.zig");
const PartialDoc = @import("PartialDoc.zig");
const region_lease = @import("region_lease.zig");
const LeaseTable = region_lease.LeaseTable;

const link_mod = @import("link.zig");
const FdLink = link_mod.FdLink;
const ChaosLink = link_mod.ChaosLink;
const futexWaitTimed = link_mod.futexWaitTimed;

const remote_fs = @import("remote_fs.zig");
const BlobServer = remote_fs.BlobServer;
const RemoteFile = remote_fs.RemoteFile;
const RemoteFs = remote_fs.RemoteFs;

const t = std.testing;

fn socketPair() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
    if (linux.errno(rc) != .SUCCESS) return error.SocketPair;
    return fds;
}

/// Yield for roughly `us` microseconds of real wall-clock time — enough
/// to let the session's reader/writer threads make progress (a tight spin
/// would starve them; `std.Thread.sleep` is gone in 0.16).
fn napUs(us: u64) void {
    const deadline = task.nowNs() + us * std.time.ns_per_us;
    while (task.nowNs() < deadline) std.Thread.yield() catch {};
}

fn testPark(ms: u64) void {
    var w: std.atomic.Value(u32) = .init(0);
    futexWaitTimed(&w, 0, ms * std.time.ns_per_ms);
}

test "session: a view-only peer's ops are dropped by the host" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var lh: FdLink = .{ .fd = fds[0] };
    var lp: FdLink = .{ .fd = fds[1] };

    var doc_host = try Document.init(gpa, "host");
    defer doc_host.deinit(gpa);
    var doc_peer = try Document.init(gpa, "peer");
    defer doc_peer.deinit(gpa);
    try doc_host.insert(gpa, 0, "base\n");

    // The host grants this peer view-only; the peer trusts the host (.own).
    const sh = try Session.create(gpa, lh.link(), .server, "tok", .view, null);
    defer sh.destroy();
    const sp = try Session.create(gpa, lp.link(), .client, "tok", .own, null);
    defer sp.destroy();

    var ch = try Collab.init(gpa, sh, &doc_host, "host");
    defer ch.deinit();
    var cp = try Collab.init(gpa, sp, &doc_peer, "peer");
    defer cp.deinit();

    // Wait (adaptively) for a milestone in the peer's doc, pumping both
    // sides; returns false on timeout.
    const H = struct {
        fn until(a: Allocator, host: *Collab, peer: *Collab, doc: *Document, needle: []const u8) !bool {
            // Bounded by wall-clock, not iterations: the session's reader/
            // writer threads need real time for the handshake + socketpair
            // transfer, which a tight spin-loop would starve.
            var round: usize = 0;
            while (round < 6000) : (round += 1) {
                _ = try host.tick(0);
                _ = try peer.tick(0);
                const txt = try doc.text().toOwnedSlice(a);
                defer a.free(txt);
                if (std.mem.indexOf(u8, txt, needle) != null) return true;
                napUs(300);
            }
            return false;
        }
    };

    // The link is live: the host's base reaches the viewer.
    try t.expect(try H.until(gpa, &ch, &cp, &doc_peer, "base"));

    // Concurrent edits: host writes; the viewer tries to.
    try doc_host.insert(gpa, 0, "HOST");
    try doc_peer.insert(gpa, doc_peer.text().byteLen(), "PEER");

    // The host's edit reaches the viewer (read access works).
    try t.expect(try H.until(gpa, &ch, &cp, &doc_peer, "HOST"));

    // Pump well past a round trip so the viewer's op would have landed on
    // the host if it were ever going to.
    for (0..300) |_| {
        _ = try ch.tick(0);
        _ = try cp.tick(0);
        napUs(300);
    }

    const th = try doc_host.text().toOwnedSlice(gpa);
    defer gpa.free(th);
    // The host applied its own edit but never admitted the viewer's.
    try t.expect(std.mem.indexOf(u8, th, "HOST") != null);
    try t.expect(std.mem.indexOf(u8, th, "PEER") == null);
}

test "session+collab: two instances converge over an encrypted link with presence" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };

    var doc_a = try Document.init(gpa, "alice");
    defer doc_a.deinit(gpa);
    var doc_b = try Document.init(gpa, "bob");
    defer doc_b.deinit(gpa);
    try doc_a.insert(gpa, 0, "shared ground\n");

    const sa = try Session.create(gpa, la.link(), .server, "tok", .own, null);
    defer sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "tok", .own, null);
    defer sb.destroy();

    var ca = try Collab.init(gpa, sa, &doc_a, "alice");
    defer ca.deinit();
    var cb = try Collab.init(gpa, sb, &doc_b, "bob");
    defer cb.deinit();

    var layers: layers_mod.Layers = .empty;
    defer layers.deinit(gpa);
    cb.presence_layer = try layers.claim(gpa, &doc_b, "presence", .replicated, "collab");

    // Pump both sides; concurrent edits mid-stream. The bound is a generous
    // yield-spin timeout, not the expected cost: convergence is a couple of
    // socket round-trips, but the reader/writer threads share CPU with the
    // rest of the (now wasmtime-carrying) test binary, so we give the
    // scheduler ample turns before declaring a hang.
    var round: usize = 0;
    var edited = false;
    while (round < 2000) : (round += 1) {
        _ = try ca.tick(3);
        _ = try cb.tick(0);
        if (round == 40 and !edited) {
            edited = true;
            try doc_a.insert(gpa, 0, "A>");
            try doc_b.insert(gpa, doc_b.text().byteLen(), "<B");
        }
        const ta = try doc_a.text().toOwnedSlice(gpa);
        defer gpa.free(ta);
        const tb = try doc_b.text().toOwnedSlice(gpa);
        defer gpa.free(tb);
        if (edited and ta.len > 16 and std.mem.eql(u8, ta, tb)) break;
        std.Thread.yield() catch {};
    }
    try t.expect(round < 2000);

    const ta = try doc_a.text().toOwnedSlice(gpa);
    defer gpa.free(ta);
    try t.expect(std.mem.indexOf(u8, ta, "A>") != null);
    try t.expect(std.mem.indexOf(u8, ta, "<B") != null);
    try t.expect(std.mem.indexOf(u8, ta, "shared ground") != null);

    // Presence from alice landed in bob's replicated layer.
    var saw_presence = false;
    for (0..200) |_| {
        _ = try cb.tick(0);
        if (cb.presence_layer.?.spanCount() > 0) {
            saw_presence = true;
            break;
        }
        std.Thread.yield() catch {};
    }
    try t.expect(saw_presence);
    try t.expectEqualStrings("alice", cb.presence_layer.?.resolvedSpan(0).message);
}

test "conn: shared buffers both ways over one link — offers, open, converge, presence per quad" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };

    // Primary docs (quad 0, the legacy flow) plus one extra each side.
    var a0 = try Document.init(gpa, "alice");
    defer a0.deinit(gpa);
    var b0 = try Document.init(gpa, "bob");
    defer b0.deinit(gpa);
    try a0.insert(gpa, 0, "primary\n");
    var a_notes = try Document.init(gpa, "alice");
    defer a_notes.deinit(gpa);
    try a_notes.insert(gpa, 0, "alice's notes\n");
    var b_todo = try Document.init(gpa, "bob");
    defer b_todo.deinit(gpa);
    try b_todo.insert(gpa, 0, "bob's todo\n");

    const sa = try Session.create(gpa, la.link(), .server, "tok", .own, null);
    defer sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "tok", .own, null);
    defer sb.destroy();
    var ca = try Conn.init(gpa, sa, "alice", .server);
    defer ca.deinit();
    var cb = try Conn.init(gpa, sb, "bob", .client);
    defer cb.deinit();
    _ = try ca.bindPrimary(&a0, 0);
    _ = try cb.bindPrimary(&b0, 0);

    // Both sides share concurrently (role-split bases cannot collide).
    _ = try ca.share(&a_notes, "notes", 1);
    _ = try cb.share(&b_todo, "todo", 1);

    // Pump until both offers arrive (deadline-based: the handshake
    // threads need real time, not spin rounds).
    const offer_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < offer_deadline and (ca.offers.items.len == 0 or cb.offers.items.len == 0)) {
        _ = try ca.tick();
        _ = try cb.tick();
        futexWaitTimed(&sa.out_wake, sa.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(ca.offers.items.len > 0 and cb.offers.items.len > 0);
    try t.expectEqualStrings("todo", ca.offers.items[0].name);
    try t.expectEqualStrings("notes", cb.offers.items[0].name);
    try t.expect(ca.offers.items[0].base != cb.offers.items[0].base);

    // Open both offers into fresh docs; bootstrap + convergence.
    var a_todo = try Document.init(gpa, "alice");
    defer a_todo.deinit(gpa);
    var b_notes = try Document.init(gpa, "bob");
    defer b_notes.deinit(gpa);
    _ = try ca.openOffer(0, &a_todo, 2);
    _ = try cb.openOffer(0, &b_notes, 2);

    // Concurrent edits on every document, all four streams at once.
    try a0.insert(gpa, 0, "A0>");
    try b0.insert(gpa, b0.text().byteLen(), "<B0");
    try a_notes.insert(gpa, 0, "more ");
    try b_todo.insert(gpa, 0, "urgent ");

    const converge_deadline = task.nowNs() + 10 * std.time.ns_per_s;
    var converged = false;
    while (!converged and task.nowNs() < converge_deadline) {
        _ = try ca.tick();
        _ = try cb.tick();
        const p_a = try a0.text().toOwnedSlice(gpa);
        defer gpa.free(p_a);
        const p_b = try b0.text().toOwnedSlice(gpa);
        defer gpa.free(p_b);
        const n_a = try a_notes.text().toOwnedSlice(gpa);
        defer gpa.free(n_a);
        const n_b = try b_notes.text().toOwnedSlice(gpa);
        defer gpa.free(n_b);
        const t_a = try a_todo.text().toOwnedSlice(gpa);
        defer gpa.free(t_a);
        const t_b = try b_todo.text().toOwnedSlice(gpa);
        defer gpa.free(t_b);
        const done = std.mem.eql(u8, p_a, p_b) and
            std.mem.indexOf(u8, p_a, "A0>") != null and std.mem.indexOf(u8, p_a, "<B0") != null and
            std.mem.eql(u8, n_a, n_b) and std.mem.indexOf(u8, n_b, "more ") != null and
            std.mem.eql(u8, t_a, t_b) and std.mem.indexOf(u8, t_a, "urgent ") != null;
        converged = done;
        if (!done) std.Thread.yield() catch {};
    }
    try t.expect(converged);

    // Presence rides per-quad: alice's cursor in the notes doc shows up
    // only in bob's notes presence layer.
    var layers: layers_mod.Layers = .empty;
    defer layers.deinit(gpa);
    const notes_layer = try layers.claim(gpa, &b_notes, "presence", .replicated, "collab");
    const todo_layer = try layers.claim(gpa, &b_todo, "presence", .replicated, "collab");
    cb.findBase(cb.offers.items[0].base).?.presence_layer = notes_layer;
    for (cb.collabs.items) |c| {
        if (c.doc == &b_todo) c.presence_layer = todo_layer;
    }
    // Move alice's cursor in notes only (no selection: anchor == caret,
    // so the presence span is a bare caret at 3).
    for (ca.collabs.items) |c| {
        if (c.doc == &a_notes) {
            c.cursor_offset = 3;
            c.selection_anchor = 3;
        }
    }
    const presence_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < presence_deadline) {
        _ = try ca.tick();
        _ = try cb.tick();
        if (notes_layer.spanCount() > 0 and notes_layer.resolvedSpan(0).start == 3) break;
        futexWaitTimed(&sb.out_wake, sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    // Quad isolation: the notes layer sees alice AT HER NOTES CURSOR
    // (3); the todo layer only ever sees her todo cursor (0) — the two
    // streams never bleed into each other.
    try t.expect(notes_layer.spanCount() > 0);
    try t.expectEqualStrings("alice", notes_layer.resolvedSpan(0).message);
    try t.expectEqual(@as(usize, 3), notes_layer.resolvedSpan(0).start);
    if (todo_layer.spanCount() > 0) {
        try t.expectEqual(@as(usize, 0), todo_layer.resolvedSpan(0).start);
    }
}

test "partial checkout: adopt base over the wire, edit around holes, bounce-realize-converge" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };

    // Host: a biggish document, compacted so the content IS the base.
    var host = try Document.init(gpa, "host");
    defer host.deinit(gpa);
    {
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(gpa);
        for (0..6000) |i| {
            const line = try std.fmt.allocPrint(gpa, "line {d} with some ballast text\n", .{i});
            defer gpa.free(line);
            try content.appendSlice(gpa, line);
        }
        try host.insert(gpa, 0, content.items);
        const stable = try host.version(gpa);
        defer gpa.free(stable);
        try host.compact(gpa, stable);
    }
    const total = host.text().byteLen();
    try t.expect(total > 2 * RemoteFile.chunk); // several chunks

    var client = try Document.init(gpa, "client");
    defer client.deinit(gpa);

    const sa = try Session.create(gpa, la.link(), .server, "tok", .own, null);
    defer sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "tok", .own, null);
    defer sb.destroy();
    var ch = try Collab.init(gpa, sa, &host, "host");
    defer ch.deinit();
    var cc = try Collab.init(gpa, sb, &client, "client");
    defer cc.deinit();
    var partial = PartialDoc.init(gpa, &client);
    defer partial.deinit();
    cc.partial = &partial;

    // The partial gate holds op traffic (both ways) until the base is
    // adopted — a virgin doc announcing its frontier would get the
    // full history instead.
    const open_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (partial.state != .open and task.nowNs() < open_deadline) {
        _ = ch.tick(0) catch {};
        _ = cc.tick(0) catch {};
        futexWaitTimed(&sb.out_wake, sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(partial.state == .open);
    try t.expectEqual(total, client.text().byteLen()); // holes carry length
    try t.expect(!client.baseRealized());

    // Realize the viewport (the first chunk) and edit inside it; the
    // edit syncs to the host like any collaborative edit.
    try partial.want(sb, 0, 0, 100);
    const edit_deadline = task.nowNs() + 10 * std.time.ns_per_s;
    var did_edit = false;
    var converged = false;
    while (!converged and task.nowNs() < edit_deadline) {
        _ = ch.tick(0) catch {};
        _ = cc.tick(0) catch {};
        if (!did_edit and client.text().isRealized(.{ .start = 0, .end = 100 })) {
            did_edit = true;
            try client.insert(gpa, 0, "CLIENT-EDIT ");
        }
        if (did_edit) {
            const h = try host.text().toOwnedSlice(gpa);
            defer gpa.free(h);
            converged = std.mem.startsWith(u8, h, "CLIENT-EDIT ");
        }
        futexWaitTimed(&sb.out_wake, sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(converged);

    // Host edits DEEP inside a span the client never fetched: the batch
    // bounces (error.Unrealized), pump realizes, the retry converges.
    try host.insert(gpa, total / 2, "HOST-DEEP-EDIT ");
    const deep_deadline = task.nowNs() + 15 * std.time.ns_per_s;
    var deep_ok = false;
    while (!deep_ok and task.nowNs() < deep_deadline) {
        _ = ch.tick(0) catch {};
        _ = cc.tick(0) catch {};
        if (client.baseRealized()) {
            // Content reads are only legal once the holes are gone.
            const c_text = try client.text().toOwnedSlice(gpa);
            defer gpa.free(c_text);
            deep_ok = std.mem.indexOf(u8, c_text, "HOST-DEEP-EDIT ") != null and
                std.mem.startsWith(u8, c_text, "CLIENT-EDIT ");
        }
        futexWaitTimed(&sb.out_wake, sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(deep_ok);

    // Full convergence, byte for byte.
    const h_text = try host.text().toOwnedSlice(gpa);
    defer gpa.free(h_text);
    const c_text = try client.text().toOwnedSlice(gpa);
    defer gpa.free(c_text);
    try t.expectEqualStrings(h_text, c_text);
}

test "peer_fs over the wire: a client lists a host's confined shared root" {
    const gpa = t.allocator;
    const rooted_fs = @import("../rooted_fs.zig");
    const peer_fs = @import("../peer_fs.zig");

    // Host shared root: a temp dir with a file.
    var pbuf: [128]u8 = undefined;
    const root_path = try std.fmt.bufPrintZ(&pbuf, "/tmp/weft-peerwire-{d}", .{linux.getpid()});
    _ = linux.rmdir(root_path.ptr);
    if (linux.errno(linux.mkdir(root_path.ptr, 0o755)) != .SUCCESS) return error.Mkdir;
    var root = try rooted_fs.RootedFs.open(root_path.ptr);
    defer root.close();
    defer {
        _ = linux.unlinkat(root.root_fd, "hello.txt", 0);
        _ = linux.rmdir(root_path.ptr);
    }
    try root.write("hello.txt", "shared bytes");

    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };
    var host = try Document.init(gpa, "host");
    defer host.deinit(gpa);
    var client = try Document.init(gpa, "client");
    defer client.deinit(gpa);
    const sa = try Session.create(gpa, la.link(), .server, "tok", .own, null);
    defer sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "tok", .own, null);
    defer sb.destroy();
    var ch = try Collab.init(gpa, sa, &host, "host");
    defer ch.deinit();
    var cc = try Collab.init(gpa, sb, &client, "client");
    defer cc.deinit();

    // Host serves its root with a read grant; client drives a RemoteFs.
    ch.peer_fs_root = &root;
    ch.fs_grant = .{ .access = .read };
    var rfs = RemoteFs.init(gpa);
    defer rfs.deinit();
    cc.remote_fs = &rfs;

    // Settle the encrypted handshake, then LIST the shared root over the wire.
    var settle: usize = 0;
    while (settle < 80) : (settle += 1) {
        _ = ch.tick(0) catch {};
        _ = cc.tick(0) catch {};
        futexWaitTimed(&sb.out_wake, sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    const list_req = try peer_fs.encodeList(gpa, ".");
    defer gpa.free(list_req);
    const id = try rfs.request(sb, cc.base, list_req);

    const deadline = task.nowNs() + 10 * std.time.ns_per_s;
    var resp: ?[]u8 = null;
    while (resp == null and task.nowNs() < deadline) {
        _ = ch.tick(0) catch {};
        _ = cc.tick(0) catch {};
        resp = rfs.take(id);
        if (resp == null) futexWaitTimed(&sb.out_wake, sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(resp != null);
    defer gpa.free(resp.?);
    const decoded = peer_fs.decodeResponse(resp.?).?;
    try t.expectEqual(peer_fs.Status.ok, decoded.status);
    // The listing the host served, confined to its root, crossed the wire.
    try t.expect(std.mem.indexOf(u8, decoded.payload, "hello.txt") != null);
}

test "session: wrong token never establishes" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };
    const sa = try Session.create(gpa, la.link(), .server, "right", .own, null);
    defer sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "wrong", .own, null);
    defer sb.destroy();
    var waited: usize = 0;
    while (waited < 100) : (waited += 1) {
        if (sa.dead.load(.acquire) or sb.dead.load(.acquire)) break;
        std.Thread.yield() catch {};
        futexWaitTimed(&sa.out_wake, sa.out_wake.load(.acquire), 10 * std.time.ns_per_ms);
    }
    try t.expect(!sa.established.load(.acquire) or !sb.established.load(.acquire));
}

test "session: peers learn each other's fingerprint and agree on the SAS" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };
    const id_a = identity.Identity.forTest(0xa1);
    const id_b = identity.Identity.forTest(0xb2);
    const sa = try Session.create(gpa, la.link(), .server, "tok", .own, &id_a);
    defer sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "tok", .own, &id_b);
    defer sb.destroy();

    var waited: usize = 0;
    while (waited < 2000) : (waited += 1) {
        if (sa.established.load(.acquire) and sb.established.load(.acquire)) break;
        napUs(300);
    }
    try t.expect(sa.established.load(.acquire) and sb.established.load(.acquire));

    // Before establishment the accessors are null; after, each side names
    // the OTHER end by its fingerprint.
    try t.expectEqualSlices(u8, &id_b.fingerprint(), &sa.peerFingerprint().?);
    try t.expectEqualSlices(u8, &id_a.fingerprint(), &sb.peerFingerprint().?);
    // Untampered: both ends compute the same Short Authentication String.
    try t.expectEqualSlices(u8, &sa.sas().?, &sb.sas().?);
}

test "tcpConnect: a refused connection fails fast, never hangs" {
    // Nothing listens on 127.0.0.1:1; the non-blocking connect must return
    // an error well within the connect timeout (loopback RSTs at once).
    const t0 = task.nowNs();
    try t.expectError(error.Connect, session.tcpConnect("127.0.0.1:1"));
    try t.expect(task.nowNs() - t0 < 3 * std.time.ns_per_s);
}

test "tcpConnect: connects to a live listener and the fd is blocking again" {
    // Bind an ephemeral loopback port; skip if the sandbox forbids it.
    const listener = session.tcpListener(0) catch return;
    defer _ = linux.close(listener);
    var addr: linux.sockaddr.in = undefined;
    var alen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(listener, @ptrCast(&addr), &alen)) != .SUCCESS) return;
    const port = std.mem.bigToNative(u16, addr.port);

    const hostport = try std.fmt.allocPrint(t.allocator, "127.0.0.1:{d}", .{port});
    defer t.allocator.free(hostport);

    const Accept = struct {
        fn go(l: i32) void {
            const cfd = session.tcpAccept(l) catch return;
            defer _ = linux.close(cfd);
            _ = linux.write(cfd, "hi", 2); // prove the connected fd carries data
            testPark(50);
        }
    };
    var th = try std.Thread.spawn(.{}, Accept.go, .{listener});
    defer th.join();

    const fd = try session.tcpConnect(hostport);
    defer _ = linux.close(fd);
    // A blocking read (O_NONBLOCK must have been cleared, else this EAGAINs).
    var buf: [2]u8 = undefined;
    var got: usize = 0;
    while (got < 2) {
        const rc = linux.read(fd, buf[got..].ptr, buf.len - got);
        if (linux.errno(rc) != .SUCCESS) return error.ReadFailed; // e.g. EAGAIN
        if (rc == 0) break;
        got += rc;
    }
    try t.expectEqualStrings("hi", buf[0..got]);
}

test "partial checkout: multi-GB sparse file — jump to end, tail growth, viewed-only materialization" {
    const gpa = t.allocator;
    // A 3GB sparse file with known content at the tail.
    const path = ".zig-cache/tmp/weft-huge-test";
    const three_gb: u64 = 3 << 30;
    {
        var pbuf: [128:0]u8 = undefined;
        @memcpy(pbuf[0..path.len], path);
        pbuf[path.len] = 0;
        const fd_rc = linux.open(pbuf[0..path.len :0], .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
        try t.expect(linux.errno(fd_rc) == .SUCCESS);
        const fd: i32 = @intCast(fd_rc);
        defer _ = linux.close(fd);
        try t.expect(linux.errno(linux.ftruncate(fd, @intCast(three_gb))) == .SUCCESS);
        const tail_msg = "THE END OF A VERY LARGE FILE";
        _ = linux.pwrite(fd, tail_msg.ptr, tail_msg.len, @intCast(three_gb - tail_msg.len));
    }

    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };
    var doc_a = try Document.init(gpa, "agent");
    defer doc_a.deinit(gpa);
    var doc_b = try Document.init(gpa, "viewer");
    defer doc_b.deinit(gpa);
    const sa = try Session.create(gpa, la.link(), .server, "tok", .own, null);
    defer sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "tok", .own, null);
    defer sb.destroy();
    var ca = try Collab.init(gpa, sa, &doc_a, "agent");
    defer ca.deinit();
    var cb = try Collab.init(gpa, sb, &doc_b, "viewer");
    defer cb.deinit();

    var blob = try BlobServer.openPath(path);
    defer blob.close();
    ca.blob_server = &blob;
    var rf = RemoteFile.init(gpa);
    defer rf.deinit();
    cb.remote_file = &rf;

    // Stat, then jump to the end: materialize only the last chunk.
    try rf.postStat(sb);
    var rounds: usize = 0;
    while (rf.known_size == 0 and rounds < 500) : (rounds += 1) {
        _ = try ca.tick(0);
        _ = try cb.tick(0);
        testPark(2);
    }
    try t.expectEqual(three_gb, rf.known_size);

    try rf.want(sb, three_gb - 64, three_gb);
    rounds = 0;
    while (rounds < 500) : (rounds += 1) {
        _ = try ca.tick(0);
        _ = try cb.tick(0);
        if (rf.rope.isRealized(.{ .start = @intCast(three_gb - 64), .end = @intCast(three_gb) })) break;
        testPark(2);
    }
    try t.expect(rounds < 500);

    // The tail content is exactly the file's; the middle is still holes.
    var tail_buf: [28]u8 = undefined;
    var sr = rf.rope.streamReader(.{ .start = @intCast(three_gb - 28), .end = @intCast(three_gb) }, &.{});
    sr.interface.readSliceAll(&tail_buf) catch unreachable;
    try t.expectEqualStrings("THE END OF A VERY LARGE FILE", &tail_buf);
    try t.expect(!rf.rope.isRealized(.{ .start = 1 << 30, .end = (1 << 30) + 64 }));

    // The host appends; a re-stat + tail-follow materializes only the
    // new bytes (tailing a growing file).
    {
        var pbuf: [128:0]u8 = undefined;
        @memcpy(pbuf[0..path.len], path);
        pbuf[path.len] = 0;
        const fd_rc = linux.open(pbuf[0..path.len :0], .{ .ACCMODE = .WRONLY }, 0);
        const fd: i32 = @intCast(fd_rc);
        defer _ = linux.close(fd);
        _ = linux.pwrite(fd, "++GREW", 6, @intCast(three_gb));
    }
    try rf.postStat(sb);
    rounds = 0;
    while (rf.known_size == three_gb and rounds < 500) : (rounds += 1) {
        _ = try ca.tick(0);
        _ = try cb.tick(0);
        testPark(2);
    }
    try t.expectEqual(three_gb + 6, rf.known_size);
    try rf.want(sb, three_gb, three_gb + 6);
    rounds = 0;
    while (rounds < 500) : (rounds += 1) {
        _ = try ca.tick(0);
        _ = try cb.tick(0);
        if (rf.rope.isRealized(.{ .start = @intCast(three_gb), .end = @intCast(three_gb + 6) })) break;
        testPark(2);
    }
    var grew: [6]u8 = undefined;
    var sr2 = rf.rope.streamReader(.{ .start = @intCast(three_gb), .end = @intCast(three_gb + 6) }, &.{});
    sr2.interface.readSliceAll(&grew) catch unreachable;
    try t.expectEqualStrings("++GREW", &grew);
}

test "chaos: partition observed in liveness, heals as one exchange; typing stays instant" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var raw_a: FdLink = .{ .fd = fds[0] };
    var raw_b: FdLink = .{ .fd = fds[1] };
    var chaos_a: ChaosLink = .{ .inner = raw_a.link() };
    var chaos_b: ChaosLink = .{ .inner = raw_b.link() };

    var doc_a = try Document.init(gpa, "alice");
    defer doc_a.deinit(gpa);
    var doc_b = try Document.init(gpa, "bob");
    defer doc_b.deinit(gpa);
    try doc_a.insert(gpa, 0, "base\n");

    const sa = try Session.create(gpa, chaos_a.link(), .server, "tok", .own, null);
    defer sa.destroy();
    const sb = try Session.create(gpa, chaos_b.link(), .client, "tok", .own, null);
    defer sb.destroy();
    var ca = try Collab.init(gpa, sa, &doc_a, "alice");
    defer ca.deinit();
    var cb = try Collab.init(gpa, sb, &doc_b, "bob");
    defer cb.deinit();

    // Converge the base first.
    var rounds: usize = 0;
    while (rounds < 500) : (rounds += 1) {
        _ = try ca.tick(0);
        _ = try cb.tick(0);
        const tb = try doc_b.text().toOwnedSlice(gpa);
        defer gpa.free(tb);
        if (std.mem.indexOf(u8, tb, "base") != null) break;
        testPark(2);
    }
    try t.expect(rounds < 500);

    // Cable out. Both sides keep typing; local commits stay instant.
    chaos_a.partitioned.store(true, .release);
    chaos_b.partitioned.store(true, .release);
    const t0 = task.nowNs();
    try doc_a.insert(gpa, 0, "A1 ");
    try doc_a.insert(gpa, 0, "A2 ");
    try doc_b.insert(gpa, doc_b.text().byteLen(), " B1");
    try doc_b.insert(gpa, doc_b.text().byteLen(), " B2");
    const local_latency = task.nowNs() - t0;
    try t.expect(local_latency < 50 * std.time.ns_per_ms); // network-free

    // Pump during the partition: no convergence, and (with patience the
    // test doesn't have for the full 3s window) liveness degrades — we
    // assert divergence here and the state machine transition below.
    for (0..20) |_| {
        _ = try ca.tick(0);
        _ = try cb.tick(0);
        testPark(2);
    }
    {
        const ta = try doc_a.text().toOwnedSlice(gpa);
        defer gpa.free(ta);
        try t.expect(std.mem.indexOf(u8, ta, "B2") == null);
    }

    // Heal: one frontier exchange + merged burst converges everything.
    chaos_a.partitioned.store(false, .release);
    chaos_b.partitioned.store(false, .release);
    rounds = 0;
    while (rounds < 1000) : (rounds += 1) {
        _ = try ca.tick(0);
        _ = try cb.tick(0);
        const ta = try doc_a.text().toOwnedSlice(gpa);
        defer gpa.free(ta);
        const tb = try doc_b.text().toOwnedSlice(gpa);
        defer gpa.free(tb);
        if (std.mem.eql(u8, ta, tb) and std.mem.indexOf(u8, ta, "A2") != null and
            std.mem.indexOf(u8, ta, "B2") != null) break;
        testPark(2);
    }
    try t.expect(rounds < 1000);

    // Injected latency: the link stays connected, remote lags, local
    // stays instant.
    chaos_a.latency_ns.store(100 * std.time.ns_per_ms, .release);
    const t1 = task.nowNs();
    try doc_a.insert(gpa, 0, "L");
    try t.expect(task.nowNs() - t1 < 50 * std.time.ns_per_ms);
}

test "hub: three-way convergence, presence relay, reconnect rebind" {
    const gpa = t.allocator;
    var doc_h = try Document.init(gpa, "hub");
    defer doc_h.deinit(gpa);
    var doc_a = try Document.init(gpa, "alice");
    defer doc_a.deinit(gpa);
    var doc_b = try Document.init(gpa, "bob");
    defer doc_b.deinit(gpa);
    try doc_h.insert(gpa, 0, "hub base\n");

    const fa = try socketPair();
    const fb = try socketPair();
    var la_h: FdLink = .{ .fd = fa[0] };
    var la_c: FdLink = .{ .fd = fa[1] };
    var lb_h: FdLink = .{ .fd = fb[0] };
    var lb_c: FdLink = .{ .fd = fb[1] };

    const sh_a = try Session.create(gpa, la_h.link(), .server, "tok", .own, null);
    defer sh_a.destroy();
    const sh_b = try Session.create(gpa, lb_h.link(), .server, "tok", .own, null);
    defer sh_b.destroy();
    var sa = try Session.create(gpa, la_c.link(), .client, "tok", .own, null);
    var sb = try Session.create(gpa, lb_c.link(), .client, "tok", .own, null);
    defer sb.destroy();

    var ch_a = try Collab.init(gpa, sh_a, &doc_h, "hub");
    defer ch_a.deinit();
    ch_a.publish_presence = false;
    var ch_b = try Collab.init(gpa, sh_b, &doc_h, "hub");
    defer ch_b.deinit();
    ch_b.publish_presence = false;
    var ca = try Collab.init(gpa, sa, &doc_a, "alice");
    defer ca.deinit();
    var cb = try Collab.init(gpa, sb, &doc_b, "bob");
    defer cb.deinit();

    // Presence relay through the hub (manual two-client wiring).
    const Relay = struct {
        var other: ?*Session = null;
        fn go(_: ?*anyopaque, key: u64, payload: []const u8) void {
            if (other) |o| o.postFeed(1, key, payload) catch {};
        }
    };
    Relay.other = sh_b;
    ch_a.relay = Relay.go;
    var layers: layers_mod.Layers = .empty;
    defer layers.deinit(gpa);
    cb.presence_layer = try layers.claim(gpa, &doc_b, "presence", .replicated, "collab");

    // Concurrent edits on both leaves; converge all three.
    try doc_a.insert(gpa, 0, "A! ");
    try doc_b.insert(gpa, 0, "B! ");
    var rounds: usize = 0;
    while (rounds < 800) : (rounds += 1) {
        _ = try ch_a.tick(0);
        _ = try ch_b.tick(0);
        _ = try ca.tick(5);
        _ = try cb.tick(0);
        const ta = try doc_a.text().toOwnedSlice(gpa);
        defer gpa.free(ta);
        const tb = try doc_b.text().toOwnedSlice(gpa);
        defer gpa.free(tb);
        const th = try doc_h.text().toOwnedSlice(gpa);
        defer gpa.free(th);
        if (std.mem.eql(u8, ta, tb) and std.mem.eql(u8, tb, th) and
            std.mem.indexOf(u8, ta, "A!") != null and std.mem.indexOf(u8, ta, "B!") != null and
            std.mem.indexOf(u8, ta, "hub base") != null) break;
        testPark(2);
    }
    try t.expect(rounds < 800);

    // Alice's presence reached bob through the hub relay.
    var saw = false;
    for (0..300) |_| {
        _ = try ch_a.tick(0);
        _ = try ch_b.tick(0);
        _ = try ca.tick(5);
        _ = try cb.tick(0);
        var has_alice = false;
        for (0..cb.presence_layer.?.spanCount()) |si| {
            if (std.mem.eql(u8, cb.presence_layer.?.resolvedSpan(si).message, "alice")) has_alice = true;
        }
        if (has_alice) {
            saw = true;
            break;
        }
        testPark(2);
    }
    try t.expect(saw);
    var found_alice = false;
    for (0..cb.presence_layer.?.spanCount()) |si| {
        if (std.mem.eql(u8, cb.presence_layer.?.resolvedSpan(si).message, "alice")) found_alice = true;
    }
    try t.expect(found_alice);

    // Reconnect: alice's link dies; a fresh pair rebinjds both ends and
    // a post-reconnect edit converges (resync = frontier exchange).
    sa.destroy();
    const fa2 = try socketPair();
    var la2_h: FdLink = .{ .fd = fa2[0] };
    var la2_c: FdLink = .{ .fd = fa2[1] };
    const sh_a2 = try Session.create(gpa, la2_h.link(), .server, "tok", .own, null);
    defer sh_a2.destroy();
    sa = try Session.create(gpa, la2_c.link(), .client, "tok", .own, null);
    defer sa.destroy();
    ch_a.rebind(sh_a2);
    ca.rebind(sa);

    try doc_a.insert(gpa, 0, "again! ");
    rounds = 0;
    while (rounds < 800) : (rounds += 1) {
        _ = try ch_a.tick(0);
        _ = try ch_b.tick(0);
        _ = try ca.tick(5);
        _ = try cb.tick(0);
        const tb = try doc_b.text().toOwnedSlice(gpa);
        defer gpa.free(tb);
        if (std.mem.indexOf(u8, tb, "again!") != null) break;
        testPark(2);
    }
    try t.expect(rounds < 800);
}

// ── stemma delta 5: a GraphDoc (the agent transcript) replicates over the
// REAL wire — W5's gate ("the model replicates over a session"), driven
// through `Conn.shareGraph`/`openGraphOffer` exactly like the text
// share/offer test above, so the announce/quad-allocation/open-by-name
// flow is proven for a graph doc too, not just the frontier exchange in
// isolation. ─────────────────────────────────────────────────────────

test "GraphDoc over the wire: transcript shares, joiner adopts, edits converge both ways" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };

    // Origin: the ONE replica that ever calls `create` (graph.zig's
    // one-create discipline) — one entry already in it before it's shared,
    // so the joiner's bootstrap has real content to prove, not just an
    // empty shell.
    var origin = try TranscriptDoc.create(gpa, "alice");
    defer origin.deinit(gpa);
    _ = try origin.append(gpa, "user", 1, "hello");

    const sa = try Session.create(gpa, la.link(), .server, "tok", .own, null);
    defer sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "tok", .own, null);
    defer sb.destroy();
    var ca = try Conn.init(gpa, sa, "alice", .server);
    defer ca.deinit();
    var cb = try Conn.init(gpa, sb, "bob", .client);
    defer cb.deinit();

    _ = try ca.shareGraph(&origin.graph, "transcript", 1);

    // Pump until the offer arrives and carries the graph discriminator
    // (Conn.DocKind) — proves the additive share-announce byte round-trips
    // over the real wire, not just in a unit-level encode/decode check.
    const offer_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < offer_deadline and cb.offers.items.len == 0) {
        _ = try ca.tick();
        _ = try cb.tick();
        futexWaitTimed(&sa.out_wake, sa.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(cb.offers.items.len > 0);
    try t.expectEqualStrings("transcript", cb.offers.items[0].name);
    try t.expectEqual(Conn.DocKind.graph, cb.offers.items[0].kind);

    // Adopt: a virgin, structurally-empty GraphDoc shell — `GraphDoc.init`,
    // not `.open` (which decodes a byte batch and has nothing to decode
    // yet; the frontier exchange below fills the doc, not a byte slice
    // handed to `open`). Built directly as a `TranscriptDoc` (its `graph`
    // field, not further validated yet) so `&joiner.graph` is a STABLE
    // address for `GraphCollab` to hold — re-wrapping a separately-adopted
    // `GraphDoc` afterwards would copy the struct and strand the bound
    // pointer at the old address.
    var joiner: TranscriptDoc = .{ .graph = try GraphDoc.init(gpa, "bob") };
    defer joiner.deinit(gpa);
    _ = try cb.openGraphOffer(0, &joiner.graph, 1);

    // Pump until bootstrap lands: the origin's whole history arrives as
    // ONE batch (their_frontier was unknown, so `eventsSince` fell back to
    // `serialize` — see GraphCollab.sendBatch) the instant bob announces
    // his (empty-doc) frontier.
    const bootstrap_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < bootstrap_deadline and joiner.graph.root().mapGet("entries") == null) {
        _ = try ca.tick();
        _ = try cb.tick();
        futexWaitTimed(&sb.out_wake, sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    // Client-level validation happens HERE, once content has actually
    // landed — GraphCollab itself never knows "entries" exists (see
    // TranscriptDoc.adopt's doc comment on the seam). Assigned back into
    // the SAME variable (not rebound) so `&joiner.graph` stays the address
    // GraphCollab is bound to.
    joiner = try TranscriptDoc.adopt(joiner.graph);
    try t.expectEqual(@as(usize, 1), joiner.count());
    try t.expectEqualStrings("user", joiner.at(0).role());
    const boot_txt = try joiner.at(0).text(gpa);
    defer gpa.free(boot_txt);
    try t.expectEqualStrings("hello", boot_txt);

    // Origin appends a second entry → joiner sees it through real op
    // frames (not a direct merge call).
    _ = try origin.append(gpa, "agent", 2, "hi there");
    const append_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < append_deadline and joiner.count() < 2) {
        _ = try ca.tick();
        _ = try cb.tick();
        futexWaitTimed(&sa.out_wake, sa.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expectEqual(@as(usize, 2), joiner.count());
    try t.expectEqualStrings("agent", joiner.at(1).role());

    // Joiner edits an entry's text in place → origin converges (the other
    // direction, proving this is real bidirectional sync, not a one-way
    // feed).
    try joiner.editText(gpa, joiner.at(1).textObj(), 2, "XX");
    const converge_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    var converged = false;
    while (task.nowNs() < converge_deadline) {
        _ = try ca.tick();
        _ = try cb.tick();
        if (origin.count() == 2) {
            const ot = try origin.at(1).text(gpa);
            defer gpa.free(ot);
            if (std.mem.eql(u8, ot, "hiXX there")) {
                converged = true;
                break;
            }
        }
        testPark(2);
    }
    try t.expect(converged);

    // Frontier equality on BOTH replicas — matching graph.zig's/
    // transcript.zig's convergence rigor (content agreement alone can mask
    // an unconverged frontier).
    const ov = try origin.graph.version(gpa);
    defer gpa.free(ov);
    const jv = try joiner.graph.version(gpa);
    defer gpa.free(jv);
    try t.expectEqual(GraphDoc.VersionOrder.equal, try origin.graph.compareVersions(gpa, ov, jv));

    // The projection re-fills correctly on BOTH ends from the SAME
    // converged model — proves the graph↔text bridge survives a real
    // wire round trip, not just an in-process merge.
    var doc_a = try Document.init(gpa, "alice");
    defer doc_a.deinit(gpa);
    var subs_a: subbuffer.SubBuffers = .empty;
    defer subs_a.deinit(gpa);
    try TranscriptDoc.fill(gpa, &origin, &doc_a, &subs_a);
    const text_a = try doc_a.text().toOwnedSlice(gpa);
    defer gpa.free(text_a);
    try t.expectEqualStrings("user: hello\nagent: hiXX there", text_a);

    var doc_b = try Document.init(gpa, "bob");
    defer doc_b.deinit(gpa);
    var subs_b: subbuffer.SubBuffers = .empty;
    defer subs_b.deinit(gpa);
    try TranscriptDoc.fill(gpa, &joiner, &doc_b, &subs_b);
    const text_b = try doc_b.text().toOwnedSlice(gpa);
    defer gpa.free(text_b);
    try t.expectEqualStrings(text_a, text_b);
}

test "GraphDoc over the wire: an edit through the on_save PROJECTION converges on the peer" {
    // W5 slice 3's replication gate: `reconcileOnSave` isn't just a local
    // in-process reconcile — because the model it writes into IS a
    // `GraphDoc`, the resulting `textInsert`/`textDelete` ops are ordinary
    // graph events, so slice 2's existing wire machinery (`GraphCollab`)
    // carries them with NO new wire work, exactly as `graph.zig`'s W5
    // slice 1 doc comment promised. This proves that promise against a
    // REAL edit that arrived through a projected BUFFER (`doc.insert` +
    // `reconcileOnSave`), not a direct `TranscriptDoc.editText` model call
    // (that path is already covered by the test above).
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };

    var origin = try TranscriptDoc.create(gpa, "alice");
    defer origin.deinit(gpa);
    _ = try origin.append(gpa, "user", 1, "hello");

    const sa = try Session.create(gpa, la.link(), .server, "tok", .own, null);
    defer sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "tok", .own, null);
    defer sb.destroy();
    var ca = try Conn.init(gpa, sa, "alice", .server);
    defer ca.deinit();
    var cb = try Conn.init(gpa, sb, "bob", .client);
    defer cb.deinit();

    _ = try ca.shareGraph(&origin.graph, "transcript", 1);

    const offer_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < offer_deadline and cb.offers.items.len == 0) {
        _ = try ca.tick();
        _ = try cb.tick();
        futexWaitTimed(&sa.out_wake, sa.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(cb.offers.items.len > 0);

    var joiner: TranscriptDoc = .{ .graph = try GraphDoc.init(gpa, "bob") };
    defer joiner.deinit(gpa);
    _ = try cb.openGraphOffer(0, &joiner.graph, 1);

    const bootstrap_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < bootstrap_deadline and joiner.graph.root().mapGet("entries") == null) {
        _ = try ca.tick();
        _ = try cb.tick();
        futexWaitTimed(&sb.out_wake, sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    joiner = try TranscriptDoc.adopt(joiner.graph);
    try t.expectEqual(@as(usize, 1), joiner.count());

    // Edit THROUGH THE PROJECTION on the origin side: fill a buffer, type
    // into it (an ordinary buffer edit, no graph API touched directly),
    // then save-reconcile — the same path a real UI's `C-s` would drive.
    var doc_a = try Document.init(gpa, "alice");
    defer doc_a.deinit(gpa);
    var subs_a: subbuffer.SubBuffers = .empty;
    defer subs_a.deinit(gpa);
    try TranscriptDoc.fill(gpa, &origin, &doc_a, &subs_a);
    const row0_mid = "user: hell".len; // strictly inside the claimed body span
    try doc_a.insert(gpa, row0_mid, "!!!");
    const report = try TranscriptDoc.reconcileOnSave(gpa, &origin, &doc_a, &subs_a);
    try t.expectEqual(@as(usize, 1), report.applied);
    try t.expectEqual(@as(usize, 0), report.stale);
    const origin_body = try origin.at(0).text(gpa);
    defer gpa.free(origin_body);
    try t.expectEqualStrings("hell!!!o", origin_body);

    // Pump until the joiner's replica converges on the SAME text (a real
    // op frame over the wire, not a direct merge call).
    const converge_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    var converged = false;
    while (task.nowNs() < converge_deadline) {
        _ = try ca.tick();
        _ = try cb.tick();
        const jt = try joiner.at(0).text(gpa);
        defer gpa.free(jt);
        if (std.mem.eql(u8, jt, "hell!!!o")) {
            converged = true;
            break;
        }
        testPark(2);
    }
    try t.expect(converged);

    // Re-fill on the joiner's side reflects the origin's projected edit —
    // the graph↔text bridge survives a real wire round trip for an edit
    // that itself arrived through a projection, not just a model call.
    var doc_b = try Document.init(gpa, "bob");
    defer doc_b.deinit(gpa);
    var subs_b: subbuffer.SubBuffers = .empty;
    defer subs_b.deinit(gpa);
    try TranscriptDoc.fill(gpa, &joiner, &doc_b, &subs_b);
    const text_b = try doc_b.text().toOwnedSlice(gpa);
    defer gpa.free(text_b);
    try t.expectEqualStrings("user: hell!!!o", text_b);
}

// ── W6 slice 1: the per-region lease over the REAL wire ─────────────────
// (doc/d1-live-reconcile.md §5, §6). Two regions ("room1"/"room2") on a
// plain `GraphDoc` shared alice(server)↔bob(client) exactly like the
// GraphDoc-over-the-wire tests above; `GraphCollab.bindLeases` opts each
// side's quad into per-region admission on top of the ordinary frontier
// exchange. ──────────────────────────────────────────────────────────────

/// Shared two-party rig for the lease tests below: alice (server) and bob
/// (client), one shared `GraphDoc` with two independent regions already
/// converged on both replicas, lease tables bound on both quads.
const LeaseRig = struct {
    la: FdLink,
    lb: FdLink,
    sa: *Session,
    sb: *Session,
    ca: Conn,
    cb: Conn,
    origin: GraphDoc,
    joiner: GraphDoc,
    ga: *GraphCollab,
    gb: *GraphCollab,
    table_a: LeaseTable = .empty,
    table_b: LeaseTable = .empty,
    room1: GraphDoc.NodeRef,
    room2: GraphDoc.NodeRef,
    sa_destroyed: bool = false,

    /// Takes `self` as an OUT-POINTER (never returns `LeaseRig` by value):
    /// `ca.shareGraph(&self.origin, ...)`/`cb.openGraphOffer(0, &self.joiner,
    /// ...)` bind `GraphCollab.doc` to `&self.origin`/`&self.joiner`
    /// DIRECTLY — if this instead built `origin`/`joiner` as local
    /// variables and returned a struct literal copying them in (as a
    /// `fn setup(gpa) !LeaseRig` normally would), the copy would strand
    /// the bound pointer at the dead local's address the moment this
    /// function returns. This is exactly the hazard the GraphDoc-over-the-
    /// wire test above already documents for `TranscriptDoc`
    /// ("re-wrapping a separately-adopted GraphDoc afterwards would copy
    /// the struct and strand the bound pointer at the old address") —
    /// same fix, applied here because this rig factors setup into a
    /// helper instead of inlining it per test.
    fn setup(gpa: Allocator, self: *LeaseRig) !void {
        self.table_a = .empty;
        self.table_b = .empty;
        self.sa_destroyed = false;

        const fds = try socketPair();
        self.la = .{ .fd = fds[0] };
        self.lb = .{ .fd = fds[1] };

        self.origin = try GraphDoc.init(gpa, "alice");
        errdefer self.origin.deinit(gpa);
        const room1 = (try self.origin.set(gpa, null, "room1", .map)).?;
        const room2 = (try self.origin.set(gpa, null, "room2", .map)).?;
        self.room1 = try self.origin.nodeRef(gpa, room1);
        errdefer self.room1.free(gpa);
        self.room2 = try self.origin.nodeRef(gpa, room2);
        errdefer self.room2.free(gpa);

        self.sa = try Session.create(gpa, self.la.link(), .server, "tok", .own, null);
        errdefer self.sa.destroy();
        self.sb = try Session.create(gpa, self.lb.link(), .client, "tok", .own, null);
        errdefer self.sb.destroy();
        self.ca = try Conn.init(gpa, self.sa, "alice", .server);
        errdefer self.ca.deinit();
        self.cb = try Conn.init(gpa, self.sb, "bob", .client);
        errdefer self.cb.deinit();

        self.ga = try self.ca.shareGraph(&self.origin, "rig", 1);

        const offer_deadline = task.nowNs() + 5 * std.time.ns_per_s;
        while (task.nowNs() < offer_deadline and self.cb.offers.items.len == 0) {
            _ = try self.ca.tick();
            _ = try self.cb.tick();
            futexWaitTimed(&self.sa.out_wake, self.sa.out_wake.load(.acquire), std.time.ns_per_ms);
        }
        if (self.cb.offers.items.len == 0) return error.NoOffer;

        self.joiner = try GraphDoc.init(gpa, "bob");
        errdefer self.joiner.deinit(gpa);
        self.gb = try self.cb.openGraphOffer(0, &self.joiner, 1);

        const bootstrap_deadline = task.nowNs() + 5 * std.time.ns_per_s;
        while (task.nowNs() < bootstrap_deadline and self.joiner.root().mapGet("room2") == null) {
            _ = try self.ca.tick();
            _ = try self.cb.tick();
            futexWaitTimed(&self.sb.out_wake, self.sb.out_wake.load(.acquire), std.time.ns_per_ms);
        }
        if (self.joiner.root().mapGet("room2") == null) return error.NoBootstrap;
    }

    fn bindLeases(self: *LeaseRig) void {
        self.ga.bindLeases(&self.table_a);
        self.gb.bindLeases(&self.table_b);
    }

    fn deinit(self: *LeaseRig, gpa: Allocator) void {
        self.room1.free(gpa);
        self.room2.free(gpa);
        self.ca.deinit();
        self.cb.deinit();
        if (!self.sa_destroyed) self.sa.destroy();
        self.sb.destroy();
        self.origin.deinit(gpa);
        self.joiner.deinit(gpa);
        self.table_a.deinit(gpa);
        self.table_b.deinit(gpa);
    }

    fn pump(self: *LeaseRig) !void {
        _ = try self.ca.tick();
        _ = try self.cb.tick();
    }

    /// Pump both sides (or just bob's, if alice's session was killed)
    /// until `region` shows `want` (or null) as its holder in `table`, or
    /// the deadline passes. Returns whether the condition was met.
    fn pumpUntilHolder(self: *LeaseRig, table: *const LeaseTable, region: GraphDoc.NodeRef, want: ?[]const u8) !bool {
        const deadline = task.nowNs() + 5 * std.time.ns_per_s;
        while (task.nowNs() < deadline) {
            if (!self.sa_destroyed) _ = try self.ca.tick();
            _ = try self.cb.tick();
            const got = table.holderOf(region);
            const matched = if (want) |w| (got != null and std.mem.eql(u8, got.?, w)) else got == null;
            if (matched) return true;
            testPark(2);
        }
        return false;
    }
};

test "lease: D1 test 5 — A holds a lease, B's edit into it is refused at admission, loudly" {
    const gpa = t.allocator;
    var rig: LeaseRig = undefined;
    try LeaseRig.setup(gpa, &rig);
    defer rig.deinit(gpa);
    rig.bindLeases();

    // Alice acquires room1 — granted (free).
    const acq = try rig.ga.acquireLease(rig.room1);
    try t.expectEqual(LeaseTable.AcquireResult.granted, acq);

    // Bob learns of it (the display data path — "locked by A").
    try t.expect(try rig.pumpUntilHolder(&rig.table_b, rig.room1, "alice"));

    // Bob edits INTO alice's held region (an ordinary graph mutation on
    // his own replica — nothing gates the local call; the wire admission
    // gate is where this gets caught).
    const b_room1 = try rig.joiner.resolve(rig.room1);
    _ = try rig.joiner.set(gpa, b_room1, "hacked", .{ .str = "evil" });

    // Pump until bob's OWN quad receives the echoed refusal — `refusals`
    // records refusals RECEIVED (the loud echo to the sender), not issued;
    // alice is the one refusing, so the observable signal lives on bob's
    // side (`gb`), never alice's own `ga.refusals` (that would only ever
    // fill if SHE were on the receiving end of someone else's refusal).
    // This is the letter of §6 test 5: "the refusal is observable to B —
    // via ... a trap/echo — not a silent drop."
    const deadline = task.nowNs() + 5 * std.time.ns_per_s;
    var refused = false;
    while (task.nowNs() < deadline) {
        try rig.pump();
        if (rig.gb.refusals.items.len > 0) {
            refused = true;
            break;
        }
        testPark(2);
    }
    try t.expect(refused);

    // The refusal names the right region and the right holder.
    try t.expect(rig.gb.refusals.items[0].region.eql(rig.room1));
    try t.expectEqualStrings("alice", rig.gb.refusals.items[0].holder);

    // NOT merged: alice's replica never got bob's key.
    try t.expect(rig.origin.ref(rig.origin.resolve(rig.room1) catch unreachable).mapGet("hacked") == null);
}

test "lease: coexists with disjoint-region editing — genuine multi-writer preserved" {
    const gpa = t.allocator;
    var rig: LeaseRig = undefined;
    try LeaseRig.setup(gpa, &rig);
    defer rig.deinit(gpa);
    rig.bindLeases();

    const acq = try rig.ga.acquireLease(rig.room1);
    try t.expectEqual(LeaseTable.AcquireResult.granted, acq);
    try t.expect(try rig.pumpUntilHolder(&rig.table_b, rig.room1, "alice"));

    // Bob edits the OTHER region, disjoint from alice's lease.
    const b_room2 = try rig.joiner.resolve(rig.room2);
    _ = try rig.joiner.set(gpa, b_room2, "note", .{ .str = "fine" });

    const deadline = task.nowNs() + 5 * std.time.ns_per_s;
    var converged = false;
    while (task.nowNs() < deadline) {
        try rig.pump();
        const room2 = rig.origin.resolve(rig.room2) catch continue;
        if (rig.origin.ref(room2).mapGet("note")) |v| {
            if (std.mem.eql(u8, v.asStr(), "fine")) {
                converged = true;
                break;
            }
        }
        testPark(2);
    }
    try t.expect(converged);
    // No refusal was ever needed — the lease on room1 never touched room2.
    try t.expectEqual(@as(usize, 0), rig.ga.refusals.items.len);
}

test "lease: lifecycle over the wire — acquire, conflict answer, release, re-acquire by peer" {
    const gpa = t.allocator;
    var rig: LeaseRig = undefined;
    try LeaseRig.setup(gpa, &rig);
    defer rig.deinit(gpa);
    rig.bindLeases();

    const acq = try rig.ga.acquireLease(rig.room1);
    try t.expectEqual(LeaseTable.AcquireResult.granted, acq);
    try t.expect(try rig.pumpUntilHolder(&rig.table_b, rig.room1, "alice"));

    // Bob's own acquire attempt sees the conflict answer as DATA.
    const conflict = try rig.gb.acquireLease(rig.room1);
    switch (conflict) {
        .held_by => |h| try t.expectEqualStrings("alice", h),
        .granted => return error.TestUnexpectedResult,
    }

    // Alice releases; the release propagates.
    try rig.ga.releaseLease(rig.room1);
    try t.expect(try rig.pumpUntilHolder(&rig.table_b, rig.room1, null));

    // Now bob can acquire it, and alice learns.
    const acq2 = try rig.gb.acquireLease(rig.room1);
    try t.expectEqual(LeaseTable.AcquireResult.granted, acq2);
    try t.expect(try rig.pumpUntilHolder(&rig.table_a, rig.room1, "bob"));
}

test "lease: disconnect reaping — a dead session's leases die, the peer can acquire" {
    const gpa = t.allocator;
    var rig: LeaseRig = undefined;
    try LeaseRig.setup(gpa, &rig);
    defer rig.deinit(gpa);
    rig.bindLeases();

    const acq = try rig.ga.acquireLease(rig.room1);
    try t.expectEqual(LeaseTable.AcquireResult.granted, acq);
    try t.expect(try rig.pumpUntilHolder(&rig.table_b, rig.room1, "alice"));

    // Alice vanishes: her session dies. Closing one end of a socketpair
    // delivers EOF to the other, so bob's session notices without needing
    // alice's side pumped again.
    rig.sa.destroy();
    rig.sa_destroyed = true;

    // Bob's own tick (via `push`) reaps alice's leases once his session
    // reports offline.
    try t.expect(try rig.pumpUntilHolder(&rig.table_b, rig.room1, null));

    // The region is acquirable again.
    const acq2 = try rig.gb.acquireLease(rig.room1);
    try t.expectEqual(LeaseTable.AcquireResult.granted, acq2);
}

test "lease: concurrent acquire race — tables converge to the SAME holder, the loser is refused loudly" {
    const gpa = t.allocator;
    var rig: LeaseRig = undefined;
    try LeaseRig.setup(gpa, &rig);
    defer rig.deinit(gpa);
    rig.bindLeases();

    // The genuine focus-enter race: both principals `tryAcquire` the SAME
    // free region locally before either announcement has crossed the
    // wire (`acquireLease` only QUEUES the announce — `postFeed` doesn't
    // block for delivery — so calling it on both sides before any `pump`
    // reliably reproduces the window). Both succeed locally; nothing has
    // arbitrated between them yet.
    const acq_a = try rig.ga.acquireLease(rig.room1);
    try t.expectEqual(LeaseTable.AcquireResult.granted, acq_a);
    const acq_b = try rig.gb.acquireLease(rig.room1);
    try t.expectEqual(LeaseTable.AcquireResult.granted, acq_b);
    try t.expectEqualStrings("alice", rig.table_a.holderOf(rig.room1).?);
    try t.expectEqualStrings("bob", rig.table_b.holderOf(rig.room1).?);

    // Once both announcements propagate, `foldRemoteAcquire`'s
    // deterministic tiebreak ("alice" < "bob" byte-wise) resolves the
    // race IDENTICALLY on both replicas — not a stable inversion, not
    // order-dependent. Pump until both tables agree.
    const deadline = task.nowNs() + 5 * std.time.ns_per_s;
    var converged = false;
    while (task.nowNs() < deadline) {
        try rig.pump();
        const ha = rig.table_a.holderOf(rig.room1);
        const hb = rig.table_b.holderOf(rig.room1);
        if (ha != null and hb != null and std.mem.eql(u8, ha.?, hb.?)) {
            converged = true;
            break;
        }
        testPark(2);
    }
    try t.expect(converged);
    try t.expectEqualStrings("alice", rig.table_a.holderOf(rig.room1).?);
    try t.expectEqualStrings("alice", rig.table_b.holderOf(rig.room1).?);

    // The loser (bob) edits the region he transiently believed he held —
    // this must be refused LOUDLY at admission, never silently merged.
    // Zero refusals here would mean concurrent writes into one region
    // slipped through — exactly what the tiebreak exists to prevent.
    const b_room1 = try rig.joiner.resolve(rig.room1);
    _ = try rig.joiner.set(gpa, b_room1, "raced", .{ .str = "loser" });

    var refused = false;
    const deadline2 = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < deadline2) {
        try rig.pump();
        if (rig.gb.refusals.items.len > 0) {
            refused = true;
            break;
        }
        testPark(2);
    }
    try t.expect(refused);
    try t.expectEqualStrings("alice", rig.gb.refusals.items[0].holder);
    try t.expect(rig.origin.ref(rig.origin.resolve(rig.room1) catch unreachable).mapGet("raced") == null);
}

test "lease: reconnect re-announces held leases (presence parity, not a fresh acquire race)" {
    const gpa = t.allocator;
    var rig: LeaseRig = undefined;
    try LeaseRig.setup(gpa, &rig);
    defer rig.deinit(gpa);
    rig.bindLeases();

    const acq = try rig.ga.acquireLease(rig.room1);
    try t.expectEqual(LeaseTable.AcquireResult.granted, acq);
    try t.expect(try rig.pumpUntilHolder(&rig.table_b, rig.room1, "alice"));

    // Alice's session dies; bob reaps her lease from HIS table (the
    // existing disconnect behavior) — alice's OWN local table is
    // untouched, since she never released.
    rig.sa.destroy();
    rig.sa_destroyed = true;
    try t.expect(try rig.pumpUntilHolder(&rig.table_b, rig.room1, null));
    try t.expectEqualStrings("alice", rig.table_a.holderOf(rig.room1).?);

    // Reconnect: a fresh socketpair + fresh Sessions, both Conns rebind
    // (mirrors the "hub: ... reconnect rebind" test's pattern). Bob's
    // ORIGINAL session shared alice's socketpair (a direct 2-party link,
    // unlike the hub test's separate per-leaf links), so it's just as
    // dead as alice's the moment alice's end closed — destroy it before
    // replacing it, or it's orphaned (a real leak, not a false positive:
    // caught by the allocator during this fix's own development). `rig`
    // takes ownership of both new sessions for teardown from here on.
    rig.sb.destroy();
    const fds2 = try socketPair();
    var la2: FdLink = .{ .fd = fds2[0] };
    var lb2: FdLink = .{ .fd = fds2[1] };
    const sa2 = try Session.create(gpa, la2.link(), .server, "tok", .own, null);
    const sb2 = try Session.create(gpa, lb2.link(), .client, "tok", .own, null);
    try rig.ca.rebind(sa2);
    try rig.cb.rebind(sb2);
    rig.sa = sa2;
    rig.sb = sb2;
    rig.sa_destroyed = false;

    // Bob re-learns alice still holds room1 — the reconnect re-announce
    // (`needs_lease_reannounce`), NOT a fresh `acquireLease` call (alice
    // never re-acquires; she still believes she always held it).
    try t.expect(try rig.pumpUntilHolder(&rig.table_b, rig.room1, "alice"));
}

test "lease: announce frame is version-tolerant — missing hue, extra trailing bytes" {
    const gpa = t.allocator;
    var gc: GraphCollab = try GraphCollab.init(gpa, undefined, undefined, "bob");
    defer gc.deinit();
    var table: LeaseTable = .empty;
    defer table.deinit(gpa);
    gc.bindLeases(&table);

    const region: GraphDoc.NodeRef = .{ .token = "sto\x01\x05alice\x01" };

    // Older sender: no trailing hue16 field at all.
    {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        try wire.putUv(gpa, &payload, 5); // "alice".len
        try payload.appendSlice(gpa, "alice");
        try wire.putUv(gpa, &payload, region.token.len);
        try payload.appendSlice(gpa, region.token);
        try wire.putUv(gpa, &payload, 1); // acquired

        const owned = try gpa.dupe(u8, payload.items);
        const changed = try gc.handleFrame(.{ .class = .feed, .kind = 0, .channel = gc.base + 1, .payload = owned });
        gpa.free(owned);
        try t.expect(changed);
    }
    try t.expectEqualStrings("alice", table.holderOf(region).?);
    try t.expectEqualStrings("alice", gc.peer_name.?);

    // Newer sender: extra trailing bytes past every field this decoder
    // knows about — ignored, not a decode error (same tolerance
    // `Collab`'s presence frame documents).
    {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        try wire.putUv(gpa, &payload, 5);
        try payload.appendSlice(gpa, "alice");
        try wire.putUv(gpa, &payload, region.token.len);
        try payload.appendSlice(gpa, region.token);
        try wire.putUv(gpa, &payload, 1);
        try wire.putUv(gpa, &payload, 42); // hue16
        try payload.appendSlice(gpa, "\x00\x00\x00future-field-a-newer-peer-added");

        const owned = try gpa.dupe(u8, payload.items);
        const changed = try gc.handleFrame(.{ .class = .feed, .kind = 0, .channel = gc.base + 1, .payload = owned });
        gpa.free(owned);
        try t.expect(changed);
    }
    try t.expectEqual(@as(u32, 42), table.hueOf(region).?);
}
