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
const wire = @import("weft_wire");
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
const grants = @import("../grants.zig");

const link_mod = @import("link.zig");
const FdLink = link_mod.FdLink;
const ChaosLink = link_mod.ChaosLink;
const futexWaitTimed = link_mod.futexWaitTimed;
const VirtualClock = @import("clock.zig").Virtual;

const peer_fs = @import("../peer_fs.zig");
const rooted_fs = @import("../rooted_fs.zig");
const remote_fs = @import("remote_fs.zig");
const BlobServer = remote_fs.BlobServer;
const RemoteFile = remote_fs.RemoteFile;
const RemoteFs = remote_fs.RemoteFs;
const requests = @import("requests.zig");

const syntax_claim = @import("../syntax_claim.zig");

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

/// Is anything queued on `fd` right now? Asserting the ABSENCE of delivery
/// needs a question that answers immediately; a read would just block.
fn readable(fd: i32) bool {
    var pfd: linux.pollfd = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
    return linux.poll(@ptrCast(&pfd), 1, 0) == 1;
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
    ca.publish_presence = true; // alice selects cursor sharing

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

test "collab: a programmatic share emits no presence; selecting it publishes, withdrawing retracts" {
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

    // Text converges with alice's caret parked at 3 — and bob sees no caret.
    const converge_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < converge_deadline and doc_b.text().byteLen() < doc_a.text().byteLen()) {
        _ = try ca.tick(3);
        _ = try cb.tick(0);
        futexWaitTimed(&sb.out_wake, sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expectEqual(doc_a.text().byteLen(), doc_b.text().byteLen());
    for (0..200) |_| {
        _ = try ca.tick(3);
        _ = try cb.tick(0);
        std.Thread.yield() catch {};
    }
    try t.expectEqual(@as(usize, 0), cb.presence_layer.?.spanCount());

    // Selecting it publishes over the same link, without a further move.
    try ca.setPublishPresence(true);
    const presence_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < presence_deadline and cb.presence_layer.?.spanCount() == 0) {
        _ = try ca.tick(3);
        _ = try cb.tick(0);
        futexWaitTimed(&sb.out_wake, sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(cb.presence_layer.?.spanCount() > 0);
    try t.expectEqualStrings("alice", cb.presence_layer.?.resolvedSpan(0).message);

    // Withdrawing it retracts the caret rather than leaving bob rendering
    // alice's last position forever.
    try ca.setPublishPresence(false);
    const retract_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < retract_deadline and cb.presence_layer.?.spanCount() > 0) {
        _ = try ca.tick(3);
        _ = try cb.tick(0);
        futexWaitTimed(&sb.out_wake, sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expectEqual(@as(usize, 0), cb.presence_layer.?.spanCount());
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
    // Alice selects cursor sharing, then moves her cursor in notes only
    // (no selection: anchor == caret, so the span is a bare caret at 3).
    for (ca.collabs.items) |c| {
        c.publish_presence = true;
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
    ch.fs_grant = .read;
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
        resp = try rfs.take(id);
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

test "Session: authenticated identities survive a real TCP connection" {
    const listener = session.tcpListener(0) catch return;
    defer _ = linux.close(listener);
    const port = try session.tcpListenerPort(listener);
    const hostport = try std.fmt.allocPrint(t.allocator, "127.0.0.1:{d}", .{port});
    defer t.allocator.free(hostport);

    const client_fd = try session.tcpConnect(hostport);
    const server_fd = try session.tcpAccept(listener);
    var server_link: session.FdLink = .{ .fd = server_fd };
    var client_link: session.FdLink = .{ .fd = client_fd };
    var server_id = identity.Identity.generate();
    var client_id = identity.Identity.generate();
    const server = try session.Session.create(t.allocator, server_link.link(), .server, "tcp-auth-test", .own, &server_id);
    defer server.destroy();
    const client = try session.Session.create(t.allocator, client_link.link(), .client, "tcp-auth-test", .own, &client_id);
    defer client.destroy();

    var waited: usize = 0;
    while (waited < 2000) : (waited += 1) {
        if (server.established.load(.acquire) and client.established.load(.acquire)) break;
        napUs(300);
    }
    try t.expect(server.established.load(.acquire) and client.established.load(.acquire));
    try t.expectEqualSlices(u8, &client_id.fingerprint(), &server.peerFingerprint().?);
    try t.expectEqualSlices(u8, &server_id.fingerprint(), &client.peerFingerprint().?);
    try t.expectEqualSlices(u8, &server.sas().?, &client.sas().?);
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

test "chaos: propagation latency pipelines writes without throttling the sender" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var sender: FdLink = .{ .fd = fds[0] };
    var receiver: FdLink = .{ .fd = fds[1] };
    defer receiver.link().close();
    var virtual: VirtualClock = .{};
    var chaos: ChaosLink = .{};
    try chaos.startOn(gpa, sender.link(), virtual.clock());
    defer chaos.close();
    chaos.configureLatency(200 * std.time.ns_per_ms, 0, 0);

    const started = task.nowNs();
    const link = chaos.link();
    try link.write("abc");
    try link.write("def");
    // Propagation delay belongs to delivery, not to each caller. The old
    // implementation blocked here for ~400ms (one sleep per write).
    try t.expect(task.nowNs() - started < 50 * std.time.ns_per_ms);

    // The delay still gates the wire, it just costs no wall time: the
    // worker has had every chance to run and has delivered nothing,
    // because modelled time has not reached eligibility.
    testPark(20);
    try t.expect(!readable(fds[1]));

    virtual.advance(200 * std.time.ns_per_ms);
    var got: [6]u8 = undefined;
    var used: usize = 0;
    while (used < got.len) used += try receiver.link().read(got[used..]);
    try t.expectEqualStrings("abcdef", &got);
    try t.expect(task.nowNs() - started < 200 * std.time.ns_per_ms);
}

test "session: modelled silence walks liveness connected → degraded → offline" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var raw_a: FdLink = .{ .fd = fds[0] };
    var raw_b: FdLink = .{ .fd = fds[1] };
    var virtual: VirtualClock = .{};

    // The cable comes out before any modelled time passes, which is what
    // makes this deterministic rather than merely fast: the writer's
    // heartbeat is itself on the injected clock, so at a frozen zero no
    // heartbeat is ever produced, and once partitioned none can land and
    // refresh a last-receive stamp. Liveness is then a pure function of
    // the clock this test holds.
    var chaos_a: ChaosLink = .{};
    try chaos_a.startOn(gpa, raw_a.link(), virtual.clock());
    defer chaos_a.close();
    var chaos_b: ChaosLink = .{};
    try chaos_b.startOn(gpa, raw_b.link(), virtual.clock());
    defer chaos_b.close();

    const sa = try Session.createOn(gpa, chaos_a.link(), .server, "tok", .own, null, virtual.clock());
    defer sa.destroy();
    const sb = try Session.createOn(gpa, chaos_b.link(), .client, "tok", .own, null, virtual.clock());
    defer sb.destroy();

    var waited: usize = 0;
    while (waited < 2000) : (waited += 1) {
        if (sa.established.load(.acquire) and sb.established.load(.acquire)) break;
        napUs(300);
    }
    try t.expectEqual(Session.Liveness.connected, sa.liveness());
    try t.expectEqual(Session.Liveness.connected, sb.liveness());

    chaos_a.partitioned.store(true, .release);
    chaos_b.partitioned.store(true, .release);

    // Both thresholds are exclusive: sitting exactly on one is still the
    // gentler grade.
    virtual.advance(3 * std.time.ns_per_s);
    try t.expectEqual(Session.Liveness.connected, sa.liveness());
    virtual.advance(std.time.ns_per_s);
    try t.expectEqual(Session.Liveness.degraded, sa.liveness());
    try t.expectEqual(Session.Liveness.degraded, sb.liveness());

    virtual.advance(6 * std.time.ns_per_s);
    try t.expectEqual(Session.Liveness.degraded, sa.liveness());
    virtual.advance(std.time.ns_per_s);
    try t.expectEqual(Session.Liveness.offline, sa.liveness());
    try t.expectEqual(Session.Liveness.offline, sb.liveness());
}

test "chaos: partition observed in liveness, heals as one exchange; typing stays instant" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var raw_a: FdLink = .{ .fd = fds[0] };
    var raw_b: FdLink = .{ .fd = fds[1] };
    var chaos_a: ChaosLink = .{};
    try chaos_a.start(gpa, raw_a.link());
    errdefer chaos_a.close();
    var chaos_b: ChaosLink = .{};
    try chaos_b.start(gpa, raw_b.link());
    errdefer chaos_b.close();

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

    // Pump during the partition: no convergence. The liveness degrade the
    // same silence produces is proved on an injected clock by the
    // connected → degraded → offline test above.
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
    chaos_a.configureLatency(100 * std.time.ns_per_ms, 0, 0);
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

    // The hub relays presence; it has no cursor of its own to publish.
    var ch_a = try Collab.init(gpa, sh_a, &doc_h, "hub");
    defer ch_a.deinit();
    var ch_b = try Collab.init(gpa, sh_b, &doc_h, "hub");
    defer ch_b.deinit();
    var ca = try Collab.init(gpa, sa, &doc_a, "alice");
    defer ca.deinit();
    ca.publish_presence = true; // alice selects cursor sharing
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

    // Reconnect: alice's link dies; a fresh pair rebinds both ends and
    // a post-reconnect edit converges (resync = frontier exchange).
    const old_incarnation = sa.incarnation();
    try t.expectEqual(old_incarnation, sa.incarnation());
    sa.destroy();
    const fa2 = try socketPair();
    var la2_h: FdLink = .{ .fd = fa2[0] };
    var la2_c: FdLink = .{ .fd = fa2[1] };
    const sh_a2 = try Session.create(gpa, la2_h.link(), .server, "tok", .own, null);
    defer sh_a2.destroy();
    sa = try Session.create(gpa, la2_c.link(), .client, "tok", .own, null);
    defer sa.destroy();
    const new_incarnation = sa.incarnation();
    try t.expect(!std.mem.eql(u8, &old_incarnation, &new_incarnation));
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

// ── W6 check-in: TranscriptDoc live over the wire, confined by a subtree
// grant (doc/substrate.md, in full: "attach to the
// daemon's headless agent session, observe via slot-fired scenes,
// intervene under grant, detach, session unaffected"). CORRECTED CLAIM (an
// earlier version of this comment overstated what this test drives): the
// producer side here calls `TranscriptDoc.append`/`editText` DIRECTLY —
// the model API `quickjs.zig`'s `cTranscriptEntry`/`cTranscriptAppend` are
// a thin membrane wrapper OVER (arg-unmarshal, single-instance-transcript
// lookup, then exactly these two calls, then a re-fill). This test proves
// the MODEL + its replication + grant enforcement + the push re-fill
// trigger + a real disconnect/reconnect cycle — it does NOT exercise the
// membrane handlers, the JS runtime, or `config/plugins/acp.js` at all
// (see `quickjs.zig`'s own seam test(s) for that layer), and it does NOT
// exercise "scenes" literally (§1's own doctrine: scenes never cross the
// wire — what replicates is the GRAPH DOC; "observe via slot-fired scenes"
// is realized here as fill/refillOnChange projecting the converged model
// locally on each side, exactly as a remote head's UI slot would).
//
// **The listen path, judged honestly**: this rig is the same socketpair +
// `Session`/`Conn` harness every OTHER integration test in this file uses
// (`GraphDoc over the wire`, the lease suite, the subtree-grant suite) —
// not `core/hub.zig`'s `Hub.listen` (a real, headlessly-testable TCP
// accept loop; `headless.zig` drives it with no app/GUI loop at all,
// confirmed by reading that file). `Hub` was considered and rejected for
// THIS test specifically: real TCP sockets are the one part of this rig
// that can be sandbox-dependent (the existing `tcpConnect` tests already
// `catch return`/skip when binding is forbidden — see below), which is
// exactly the kind of environment-dependent flake this repo's own gate
// notes warn about; a "gate test" that can silently skip its own
// assertions in the environment gates are checked in is worse than one
// that uses a slightly lower-fidelity but fully deterministic harness.
// `Hub.Peer.conn` IS a `Conn` (this same type) wrapping an accepted `fd`
// into a `Session` exactly like `FdLink` wraps a socketpair fd here — so
// this rig exercises the identical `Session`/`Conn`/`GraphCollab` code
// `Hub` would drive, just fed a deterministic pipe instead of a real
// socket. What's SEPARATE, real, and honestly still missing: `headless.
// zig`'s `configure` callback (`HeadlessCfg`) only binds ONE primary TEXT
// `Document` per peer — there is no headless "agent session" concept, no
// `TranscriptDoc`, and no `Conn.shareGraph` call anywhere in
// `--headless`'s listen path today. Wiring that in is real, un-built
// plumbing (a `--headless --agent`-shaped mode, or a `System.agent_ux`-ish
// second system per §2.7) — named here as the recorded remainder, not
// papered over: nothing about `Hub`/`Conn`/`GraphCollab` blocks it: it is
// purely a missing CALLER, not a missing mechanism.
//
// Stage 4 (detach/re-attach) below is new; stages 1-3 (attach, observe
// live, intervene under grant, refuse out-of-grant) were already covered
// before this pass — see `git log -p` on this test for the boundary if it
// matters. ───────────────────────────────────────────────────────────────

test "W6 check-in: a home session streams a live transcript; a remote observer converges via push re-fill, is confined to its granted entry while streaming continues, then detaches and RE-ATTACHES (same identity) without disturbing home or losing its grant" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };

    // "Home": the headless agent session's own replica — the ONE `create`
    // call (graph.zig's one-create discipline). One turn already landed
    // before the remote attaches, like a session already running when you
    // check in.
    var home = try TranscriptDoc.create(gpa, "home");
    defer home.deinit(gpa);
    const e0 = try home.append(gpa, "user", 1, "start the refactor");
    const e0_ref = try home.graph.nodeRef(gpa, e0);
    defer e0_ref.free(gpa);

    // The remote's PERSISTENT identity — reused verbatim across the
    // detach/re-attach below (stage 4). This matters structurally, not
    // just for test plumbing: `GraphCollab.grantSubtree` keys its row on
    // `session.peerFingerprint()`, the authenticated peer identity derived
    // from this keypair (REQUIRED FIX 1, see that function's doc comment) —
    // never a self-declared name and never the `*Session` object itself. A
    // reconnecting peer that authenticates with the SAME keypair is, by
    // that mechanism, unambiguously the SAME grantee, so its standing grant
    // survives a fresh `Session`/`Conn.rebind` with no re-grant needed. If
    // the remote reconnected with a FRESH identity instead (as every OTHER
    // reconnect test in this file passes `null` and gets one) it would
    // authenticate as a stranger and its old grant would not apply — an
    // honest consequence of identity-keyed authority, not a bug in this
    // test's setup. That stranger-gains-nothing property is asserted by
    // the "subtree grant: SPOOFED peer_name ..." and "...no grant rows of
    // its own is unaffected" tests below, not re-proven here.
    const remote_id = identity.Identity.forTest(0xc6);

    // `sa`/`sb` are `var`, not `const`: stage 4 destroys and replaces both
    // wholesale on reconnect (mirrors the "hub: ... reconnect rebind"
    // test's pattern — the ORIGINAL sessions get no `defer`, since they're
    // explicitly destroyed mid-test; only whichever session is CURRENT at
    // function exit is deferred, at the point it's created).
    var sa = try Session.create(gpa, la.link(), .server, "tok", .own, null);
    var sb = try Session.create(gpa, lb.link(), .client, "tok", .own, &remote_id);
    var ca = try Conn.init(gpa, sa, "home", .server);
    defer ca.deinit();
    var cb = try Conn.init(gpa, sb, "remote", .client);
    defer cb.deinit();

    const ga = try ca.shareGraph(&home.graph, "transcript", 1);

    const offer_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < offer_deadline and cb.offers.items.len == 0) {
        _ = try ca.tick();
        _ = try cb.tick();
        futexWaitTimed(&sa.out_wake, sa.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(cb.offers.items.len > 0);
    try t.expectEqual(Conn.DocKind.graph, cb.offers.items[0].kind);

    // Built directly as a `TranscriptDoc`, `adopt`ed back into this SAME
    // variable below — the pointer-stability discipline `TranscriptDoc.
    // adopt`'s own doc comment now spells out in full (a real footgun a W6
    // remote observer hits on its very first wire-bootstrap, not just a
    // test-plumbing nicety).
    var remote: TranscriptDoc = .{ .graph = try GraphDoc.init(gpa, "remote") };
    defer remote.deinit(gpa);
    const gb = try cb.openGraphOffer(0, &remote.graph, 1);

    const bootstrap_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < bootstrap_deadline and remote.graph.root().mapGet("entries") == null) {
        _ = try ca.tick();
        _ = try cb.tick();
        futexWaitTimed(&sb.out_wake, sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    remote = try TranscriptDoc.adopt(remote.graph);
    try t.expectEqual(@as(usize, 1), remote.count());

    // The observer's own projected buffer — from here on, re-filled ONLY
    // through the push trigger (`refillOnChange`, fed by `cb.tick()`'s own
    // changed bool), never a manual extra `fill()` call, so the test
    // actually exercises live-projection freshness rather than masking a
    // missing push path behind a final catch-up fill.
    var doc_r = try Document.init(gpa, "remote");
    defer doc_r.deinit(gpa);
    var subs_r: subbuffer.SubBuffers = .empty;
    defer subs_r.deinit(gpa);
    try TranscriptDoc.fill(gpa, &remote, &doc_r, &subs_r); // the initial pull, matching a buffer just opened

    // Grant: the remote observer may intervene ONLY on the first entry
    // (the identity-anchored subtree grant W6 adds) — never the whole
    // transcript, so home's own continued streaming stays authoritative
    // and unaffected by anything the remote does elsewhere.
    var grant_table = grants.HandleTable.init(gpa);
    defer grant_table.deinit();
    ga.bindGrants(&grant_table);
    _ = try ga.grantSubtree(e0_ref);

    // Streaming continues: home appends a second entry, then streams a
    // chunk onto it — simulating an agent's turn landing while the remote
    // is attached, calling `TranscriptDoc.append`/`editText` directly — the
    // model API `cTranscriptEntry`/`cTranscriptAppend` wrap, NOT those
    // handlers themselves (see this section's corrected header comment) —
    // each followed by an immediate `fill()` of home's OWN projection (the
    // LOCAL half of live-projection freshness this test exercises directly;
    // see `transcript.zig`'s `refillOnChange` doc comment for the REMOTE
    // half, exercised below via `cb.tick()`).
    var doc_h = try Document.init(gpa, "home");
    defer doc_h.deinit(gpa);
    var subs_h: subbuffer.SubBuffers = .empty;
    defer subs_h.deinit(gpa);
    try TranscriptDoc.fill(gpa, &home, &doc_h, &subs_h);

    _ = try home.append(gpa, "agent", 2, "Looking at ");
    try TranscriptDoc.fill(gpa, &home, &doc_h, &subs_h); // local append: immediate re-fill
    const e1_text_obj = home.at(1).textObj();
    try home.editText(gpa, e1_text_obj, "Looking at ".len, "the module now.");
    try TranscriptDoc.fill(gpa, &home, &doc_h, &subs_h); // local stream chunk: immediate re-fill

    // The remote converges on the new entry AND its own projected buffer
    // catches up — through nothing but `refillOnChange` fed by
    // `cb.tick()`'s changed bool, inside the SAME pump loop that waits for
    // convergence (no separate catch-up fill after the loop below).
    const stream_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    var streamed = false;
    while (task.nowNs() < stream_deadline) {
        _ = try ca.tick();
        const changed = try cb.tick();
        try TranscriptDoc.refillOnChange(gpa, &remote, &doc_r, &subs_r, changed);
        if (remote.count() == 2) {
            const rt = try remote.at(1).text(gpa);
            defer gpa.free(rt);
            if (std.mem.eql(u8, rt, "Looking at the module now.")) {
                streamed = true;
                break;
            }
        }
        testPark(2);
    }
    try t.expect(streamed);
    {
        const got = try doc_r.text().toOwnedSlice(gpa);
        defer gpa.free(got);
        try t.expectEqualStrings("user: start the refactor\nagent: Looking at the module now.", got);
    }

    // Intervene UNDER GRANT: the remote edits entry 0's body — inside its
    // granted subtree — and it lands on home's replica.
    try remote.editText(gpa, remote.at(0).textObj(), "start the refactor".len, "!!");
    const grant_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    var landed = false;
    while (task.nowNs() < grant_deadline) {
        _ = try ca.tick();
        _ = try cb.tick();
        const ht = try home.at(0).text(gpa);
        defer gpa.free(ht);
        if (std.mem.eql(u8, ht, "start the refactor!!")) {
            landed = true;
            break;
        }
        testPark(2);
    }
    try t.expect(landed);
    try t.expectEqual(@as(usize, 0), gb.refusals.items.len);

    // Frontier equality on the ALLOWED edit — not just content agreement
    // (graph.zig's own convergence rigor) — checked HERE, before the
    // refused edit below gives `remote` a local-only op home never merges
    // (by design: a refused SEND still applies locally, see
    // `GraphCollab.admitRegions`'s "deferred-until-release" doc comment),
    // which would otherwise make the two frontiers genuinely diverge.
    {
        const hv = try home.graph.version(gpa);
        defer gpa.free(hv);
        const rv = try remote.graph.version(gpa);
        defer gpa.free(rv);
        try t.expectEqual(GraphDoc.VersionOrder.equal, try home.graph.compareVersions(gpa, hv, rv));
    }

    // Both projections render this shared, converged state identically —
    // "two principals, one model, different projections, converging" —
    // checked HERE (before the OUT-OF-GRANT edit at the very end of this
    // test gives `remote` a real local divergence of its own, by design;
    // see that block's own note on why it has to come last).
    try TranscriptDoc.fill(gpa, &home, &doc_h, &subs_h);
    {
        const text_h = try doc_h.text().toOwnedSlice(gpa);
        defer gpa.free(text_h);
        try TranscriptDoc.refillOnChange(gpa, &remote, &doc_r, &subs_r, true);
        const text_r = try doc_r.text().toOwnedSlice(gpa);
        defer gpa.free(text_r);
        try t.expectEqualStrings(text_h, text_r);
    }

    // ── Stage 4: DETACH, SESSION UNAFFECTED (the gate's last clause) ──────
    //
    // The remote disconnects — a real session teardown, not a soft
    // "stop ticking" fiction: `sb.destroy()` closes bob's own socket end,
    // which delivers EOF to home's reader thread. From here until
    // reconnect, `cb`/`gb` (bob's OWN Conn/GraphCollab, bound to the now-
    // freed `sb`) must never be ticked — mirroring the exact discipline
    // the "lease: disconnect reaping"/"lease: reconnect" tests already
    // established for the symmetric case (guard ticking whichever side's
    // Session object was just destroyed; only the SURVIVING peer's own
    // still-live Session is ticked to observe the other end going dead).
    sb.destroy();

    // Home's transcript keeps streaming regardless — pure model + LOCAL
    // projection work (`home.append`/`fill`), touching no session state at
    // all, so it needs no guard and no help from the wire layer noticing
    // anything: the daemon doesn't care whether anyone is watching.
    _ = try home.append(gpa, "user", 3, "keep going while I'm away");
    try TranscriptDoc.fill(gpa, &home, &doc_h, &subs_h);
    {
        const got = try doc_h.text().toOwnedSlice(gpa);
        defer gpa.free(got);
        try t.expect(std.mem.indexOf(u8, got, "keep going while I'm away") != null);
    }

    // Home's own (still-allocated) session notices the peer vanished, and
    // ticking `ca` through that stays harmless — "session unaffected"
    // means the host side neither crashes nor blocks when its one peer
    // drops. `ca`/`ga` never touch `cb`/`sb` (destroyed above) here.
    var offline_seen = false;
    const offline_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < offline_deadline) {
        _ = try ca.tick();
        if (sa.liveness() == .offline) {
            offline_seen = true;
            break;
        }
        testPark(2);
    }
    try t.expect(offline_seen);

    // Named honestly rather than asserted, because there is nothing TO
    // reap in THIS scenario: a per-region LEASE is session-scoped and IS
    // reaped on disconnect (`GraphCollab.reapIfDead`, exercised directly
    // by the "lease: disconnect reaping" test above) — but `ga`'s subtree
    // GRANT for the remote is deliberately NOT session-scoped. It is keyed
    // on `remote_id`'s fingerprint, an authenticated and PERSISTENT
    // identity (`grantSubtree`'s REQUIRED FIX 1), and nothing in
    // `GraphCollab`/`grants.zig` revokes a grant merely because its
    // holder's LINK dropped — revocation is an explicit `revoke`/
    // `revokeSubtreeGrants` call, or the grant's own root collapsing,
    // never a disconnect. That is precisely what lets the re-attach below
    // skip re-granting entirely: the SAME identity reconnecting is,
    // structurally, the SAME grantee. A `LeaseTable` was never bound on
    // this quad (only `bindGrants`), so there is no lease state here to
    // demonstrate reaping on beyond what the dedicated lease tests already
    // cover; a check-in scenario that also held a lease would reap it
    // exactly as those tests show.

    // ── RE-ATTACH: fresh sockets, fresh Sessions, SAME remote identity ──
    sa.destroy(); // home's now-dead-peered session, still allocated until here
    const fds2 = try socketPair();
    var la2: FdLink = .{ .fd = fds2[0] };
    var lb2: FdLink = .{ .fd = fds2[1] };
    sa = try Session.create(gpa, la2.link(), .server, "tok", .own, null);
    defer sa.destroy();
    sb = try Session.create(gpa, lb2.link(), .client, "tok", .own, &remote_id);
    defer sb.destroy();
    try ca.rebind(sa);
    try cb.rebind(sb);

    // Reconverge: home's backlog (the entry appended while the remote was
    // gone) arrives on the SAME `remote`/`doc_r`/`subs_r` from stages 1-3 —
    // "the second visit proves the daemon-ish property," not a fresh
    // bootstrap. Still driven through the live PUSH trigger
    // (`refillOnChange` fed by `cb.tick()`), same discipline as stage 3.
    const reattach_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    var reattached = false;
    while (task.nowNs() < reattach_deadline) {
        _ = try ca.tick();
        const changed = try cb.tick();
        try TranscriptDoc.refillOnChange(gpa, &remote, &doc_r, &subs_r, changed);
        if (remote.count() == 3) {
            const rt = try remote.at(2).text(gpa);
            defer gpa.free(rt);
            if (std.mem.eql(u8, rt, "keep going while I'm away")) {
                reattached = true;
                break;
            }
        }
        testPark(2);
    }
    try t.expect(reattached);

    // The grant SURVIVES the reconnect with no re-grant call: the remote
    // edits entry 0's body again (intervene #2), purely on the strength of
    // `remote_id` matching the row `ga.grantSubtree(e0_ref)` minted back
    // in stage 2 — no second `grantSubtree` call anywhere in this test
    // past that point.
    try remote.editText(gpa, remote.at(0).textObj(), 0, ">> ");
    const regrant_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    var relanded = false;
    while (task.nowNs() < regrant_deadline) {
        _ = try ca.tick();
        _ = try cb.tick();
        const ht = try home.at(0).text(gpa);
        defer gpa.free(ht);
        if (std.mem.eql(u8, ht, ">> start the refactor!!")) {
            relanded = true;
            break;
        }
        testPark(2);
    }
    try t.expect(relanded);
    // No refusal was generated by this legitimate, in-grant edit — same
    // "0 refusals" shape intervene #1 checked above.
    try t.expectEqual(@as(usize, 0), gb.refusals.items.len);

    // Full re-convergence, no corruption, after a real disconnect +
    // reconnect cycle — frontier equality one more time. Checked HERE,
    // before the out-of-grant edit below gives `remote` a real local
    // divergence of its own (same reason the FIRST frontier-equality
    // check above had to precede any refusal-producing edit).
    {
        const hv = try home.graph.version(gpa);
        defer gpa.free(hv);
        const rv = try remote.graph.version(gpa);
        defer gpa.free(rv);
        try t.expectEqual(GraphDoc.VersionOrder.equal, try home.graph.compareVersions(gpa, hv, rv));
    }

    // ── The negative half, deliberately LAST: an out-of-grant edit
    // permanently poisons `remote`'s outbound queue ────────────────────
    //
    // A refused AUTHORITY batch is never merged, and — unlike a LEASE
    // refusal — nothing ever "releases" a subtree-grant boundary, so this
    // sender's every future batch keeps re-including the same refused op
    // bundled with anything new (`sync_core`'s frontier-delta design:
    // home's announced frontier never advances past what it refused,
    // so `eventsSince` keeps re-offering it) — and `admitRegions` refuses
    // a batch straddling the grant boundary WHOLE, not row-by-row (see the
    // dedicated "subtree grant: a batch straddling the grant boundary is
    // refused WHOLE" test). Concretely: after THIS edit, `remote` could
    // never get another legitimate edit through either, not because
    // authority was revoked but because it would always ride bundled with
    // this one. That is why intervene #2 (proving the grant survives
    // reconnect) had to run BEFORE this, not after — an earlier draft of
    // this test tried the order the doc/cwa-prior-docs-audit.md §5 gate text lists
    // ("intervene converges → out-of-grant refuses → detach → ... →
    // re-attach → converged") with a THIRD intervene after re-attach, and
    // it failed for exactly this reason: real shipped behavior, not a
    // test bug. Recovering from a stuck AUTHORITY refusal (discarding or
    // rebasing the poisoned op) has no mechanism today — a genuine,
    // honestly-named gap this test surfaces rather than hides.
    //
    // The remote tries to edit entry 1 (home's own streamed turn) —
    // OUTSIDE the grant — refused loudly, never landing; home's streaming
    // replica is unaffected ("session unaffected"), on the reconnected
    // link exactly as it was on the original one.
    try remote.editText(gpa, remote.at(1).textObj(), 0, "XX");
    const refuse_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    var refused = false;
    while (task.nowNs() < refuse_deadline) {
        _ = try ca.tick();
        _ = try cb.tick();
        if (gb.refusals.items.len > 0) {
            refused = true;
            break;
        }
        testPark(2);
    }
    try t.expect(refused);
    try t.expectEqual(GraphCollab.RefusalReason.authority, gb.refusals.items[0].reason);
    const ht1 = try home.at(1).text(gpa);
    defer gpa.free(ht1);
    try t.expectEqualStrings("Looking at the module now.", ht1);
}

// ── W6 slice 1: the per-region lease over the REAL wire ─────────────────
// (doc/substrate.md §4). Two regions ("room1"/"room2") on a
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

// ── W6 slice 2: identity-anchored SUBTREE GRANTS (doc/substrate.md §4)
// — the second predicate over `GraphCollab.admitRegions`, composing with
// the W6 slice 1 lease above.
//
// Post-review REQUIRED FIX 1 changed the trust model these tests exercise:
// authority is now keyed on `Session.peerFingerprint()` — the AUTHENTICATED
// identity a secure handshake proves — never the self-declared `peer_name`
// a lease announcement carries. That means every test below that checks
// authority needs a REAL, established `Session` pair (not the
// `session = undefined` shorthand the version-tolerance lease test above
// gets away with, since that test never touches `self.session` at all).
// `SessionPair` is the minimal two-`Session`-over-a-socketpair rig for
// that — no `Conn`/`GraphDoc`-sharing machinery needed, since
// `admitRegions` only ever calls `self.session.peerFingerprint()`, never
// anything wire-protocol-shaped. The confinement case additionally gets a
// FULL socketpair round trip through `LeaseRig` (real `Conn`s, real
// `GraphDoc` sync) to prove the wire path end to end.

/// Two live `Session`s over one socketpair, both waited to `established` —
/// enough for `Session.peerFingerprint()` to be meaningful on either side,
/// without any `Conn`/document-sharing machinery `admitRegions` doesn't
/// need. `a`/`b` name the two ends generically (not "alice"/"bob") because
/// which one plays which role is the CALLER's choice per test.
const SessionPair = struct {
    la: FdLink,
    lb: FdLink,
    a: *Session,
    b: *Session,

    /// Out-pointer, same reasoning as `LeaseRig.setup`'s own doc comment:
    /// `Session.create` stores the `Link` it's given, and `FdLink.link()`'s
    /// `Link.ctx` POINTS BACK at the `FdLink` struct itself — returning
    /// this struct BY VALUE would copy `la`/`lb` and strand that pointer at
    /// a dead address the instant this function returned.
    fn setup(gpa: Allocator, self: *SessionPair) !void {
        const fds = try socketPair();
        self.la = .{ .fd = fds[0] };
        self.lb = .{ .fd = fds[1] };
        self.a = try Session.create(gpa, self.la.link(), .server, "tok", .own, null);
        errdefer self.a.destroy();
        self.b = try Session.create(gpa, self.lb.link(), .client, "tok", .own, null);
        errdefer self.b.destroy();
        const deadline = task.nowNs() + 5 * std.time.ns_per_s;
        while (task.nowNs() < deadline) {
            if (self.a.established.load(.acquire) and self.b.established.load(.acquire)) return;
            testPark(2);
        }
        return error.NotEstablished;
    }

    fn deinit(self: *SessionPair) void {
        self.a.destroy();
        self.b.destroy();
    }
};

/// Two docs (alice = enforcer, bob = the peer whose edits get checked)
/// with a granted-shaped structure already converged: `inside` (the
/// subtree a grant will name) and `outside` (never granted), both direct
/// children of the root map. Independent of `SessionPair` — the CRDT model
/// and the crypto session are orthogonal axes; a test wires them together
/// by choosing which `SessionPair` end a `GraphCollab` is bound to.
const GrantDocs = struct {
    alice: GraphDoc,
    bob: GraphDoc,
    inside: GraphDoc.NodeRef,
    outside: GraphDoc.NodeRef,

    fn setup(gpa: Allocator) !GrantDocs {
        var alice = try GraphDoc.init(gpa, "alice");
        errdefer alice.deinit(gpa);
        const inside_obj = (try alice.set(gpa, null, "inside", .map)).?;
        _ = (try alice.set(gpa, null, "outside", .map)).?;
        const inside_ref = try alice.nodeRef(gpa, inside_obj);
        errdefer inside_ref.free(gpa);
        const outside_obj = alice.root().mapGet("outside").?.objId().?;
        const outside_ref = try alice.nodeRef(gpa, outside_obj);
        errdefer outside_ref.free(gpa);

        const bytes = try alice.serialize(gpa);
        defer gpa.free(bytes);
        var bob = try GraphDoc.open(gpa, "bob", bytes);
        errdefer bob.deinit(gpa);

        return .{ .alice = alice, .bob = bob, .inside = inside_ref, .outside = outside_ref };
    }

    fn deinit(self: *GrantDocs, gpa: Allocator) void {
        self.inside.free(gpa);
        self.outside.free(gpa);
        self.alice.deinit(gpa);
        self.bob.deinit(gpa);
    }
};

/// A `GraphCollab` enforcing over `docs.alice`, wired to `sess` (a real,
/// established `Session` — `admitRegions` now derives authority from
/// `sess.peerFingerprint()`, so an unestablished/fake session would make
/// every grant check see "no identity").
fn makeEnforcer(gpa: Allocator, docs: *GrantDocs, sess: *Session, table: *grants.HandleTable) !GraphCollab {
    var gc = try GraphCollab.init(gpa, sess, &docs.alice, "alice");
    gc.bindGrants(table);
    return gc;
}

// Post-review: the W6 slice 2 consolidation (one dry-run pass serving both
// the authority and lease checks) had dropped the fast path `admitRegions`
// always had — every inbound batch on an ORDINARY share (no grants, no
// leases bound at all, the common case) started paying a full
// serialize+open+merge dry-run against `self.doc`'s committed HEAD that was
// previously zero cost. The fix restores a guard ahead of
// `GraphDoc.touchedRegionsWithin`; this test pins it so it can't silently
// regress again.
//
// The chosen observable: deliberately GARBAGE, structurally-invalid batch
// bytes. With the fast path intact, `admitRegions` on a `GraphCollab` with
// NEITHER table bound returns `.admit` WITHOUT ever calling
// `touchedRegionsWithin` — the garbage is never even parsed. If the guard
// regressed, `touchedRegionsWithin` WOULD run, attempt to `merge` the
// garbage into its scratch clone, and fail (`error.Corrupt` or similar) —
// turning this call into an ERROR instead of `.admit`. This is a direct,
// honest behavioral observable of "did the clone run," not an inspection
// of the guard's source text — a benchmark/timing assertion was considered
// and rejected as flaky and not meaningfully more honest than this.
// `session = undefined` is safe here: with no grant table bound,
// `gatherGrantRoots` returns before ever touching `self.session` (see its
// own early `self.grants orelse return ctx`).
test "subtree grant: an ordinary share (no grants, no leases bound) admits WITHOUT attempting the dry-run clone — the fast path (post-review restoration)" {
    const gpa = t.allocator;
    var doc = try GraphDoc.init(gpa, "alice");
    defer doc.deinit(gpa);

    var gc = try GraphCollab.init(gpa, undefined, &doc, "alice");
    defer gc.deinit();
    // Neither `bindGrants` nor `bindLeases` — the ordinary-share shape.

    const garbage = "\xff\xff\xff\xff\xff\xff\xff\xff\xff" ++
        "this is not a valid ObjectDoc event batch, at all";
    switch (try gc.admitRegions(gpa, garbage)) {
        .admit => {},
        .refuse => |r| {
            r.free(gpa);
            return error.TestUnexpectedResult;
        },
    }
}

test "subtree grant: peer confined to a granted subtree — in-region admitted, out-of-region refused with the authority reason" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();

    var docs = try GrantDocs.setup(gpa);
    defer docs.deinit(gpa);

    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    var gc = try makeEnforcer(gpa, &docs, sp.a, &table);
    defer gc.deinit();
    _ = try gc.grantSubtree(docs.inside);

    // In-region: the peer edits INSIDE the granted subtree — admitted.
    const b_inside = try docs.bob.resolve(docs.inside);
    _ = try docs.bob.set(gpa, b_inside, "k", .{ .str = "v" });
    {
        const av = try docs.alice.version(gpa);
        defer gpa.free(av);
        const batch = try docs.bob.eventsSince(gpa, av);
        defer gpa.free(batch);
        switch (try gc.admitRegions(gpa, batch)) {
            .admit => {},
            .refuse => |r| {
                r.free(gpa);
                return error.TestUnexpectedResult;
            },
        }
        // Test plumbing: advance alice's real state past the admitted
        // edit so the NEXT `eventsSince` below is a clean delta for the
        // out-of-region case alone.
        const changes = try docs.alice.merge(gpa, batch);
        gpa.free(changes);
    }

    // Out-of-region: the peer edits the "outside" map — never granted.
    const b_outside = try docs.bob.resolve(docs.outside);
    _ = try docs.bob.set(gpa, b_outside, "k2", .{ .str = "v2" });
    const av2 = try docs.alice.version(gpa);
    defer gpa.free(av2);
    const batch2 = try docs.bob.eventsSince(gpa, av2);
    defer gpa.free(batch2);
    switch (try gc.admitRegions(gpa, batch2)) {
        .refuse => |r| {
            defer r.free(gpa);
            try t.expectEqual(GraphCollab.RefusalReason.authority, r.reason);
            try t.expect(r.region.eql(docs.outside));
        },
        .admit => return error.TestUnexpectedResult,
    }
}

test "subtree grant: SPOOFED peer_name has no effect on authority — keyed on the authenticated session identity (REQUIRED FIX 1)" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();

    var docs = try GrantDocs.setup(gpa);
    defer docs.deinit(gpa);

    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    var gc = try makeEnforcer(gpa, &docs, sp.a, &table);
    defer gc.deinit();
    _ = try gc.grantSubtree(docs.inside);

    // The attacker's move: `peer_name` reads as an ARBITRARY, UNGRANTED,
    // self-declared name — exactly the field the pre-fix design keyed
    // authority on (learned from an inbound, unauthenticated lease
    // announce; see `peer_name`'s own doc comment: "no separate identity
    // handshake... same trust level as `Collab`'s presence names"). A real
    // attacker would just announce a lease under this name; setting the
    // field directly is the same thing without needing the wire.
    gc.peer_name = try gpa.dupe(u8, "eve");

    // The same spoofed name doesn't cause a false REFUSAL inside the grant
    // — `peer_name` is simply never consulted for authority. Checked FIRST
    // (its own clean batch, then merged as test plumbing) so the second,
    // load-bearing check below starts from a clean delta rather than a
    // batch straddling both edits.
    const b_inside = try docs.bob.resolve(docs.inside);
    _ = try docs.bob.set(gpa, b_inside, "fine", .{ .str = "ok" });
    {
        const av = try docs.alice.version(gpa);
        defer gpa.free(av);
        const batch = try docs.bob.eventsSince(gpa, av);
        defer gpa.free(batch);
        switch (try gc.admitRegions(gpa, batch)) {
            .admit => {},
            .refuse => |r| {
                r.free(gpa);
                return error.TestUnexpectedResult;
            },
        }
        const changes = try docs.alice.merge(gpa, batch);
        gpa.free(changes);
    }

    // Edit OUTSIDE the granted subtree. Pre-fix, `checkSubtreeGrants`
    // looked up rows for "eve": `doc_has_grants = true` (the doc has a row,
    // for the REAL peer), `peer_has_grants = false` (no row literally named
    // "eve") — and the design's own "absence of a grant row keeps today's
    // behavior" rule then read that as UNRESTRICTED, silently admitting a
    // whole-doc edit from a peer that renamed its way out of its own
    // confinement. Must now refuse `.authority`: the AUTHENTICATED identity
    // (this quad's real session peer) is exactly who holds the grant,
    // independent of whatever `peer_name` claims.
    const b_outside = try docs.bob.resolve(docs.outside);
    _ = try docs.bob.set(gpa, b_outside, "hacked", .{ .str = "evil" });
    const av2 = try docs.alice.version(gpa);
    defer gpa.free(av2);
    const batch2 = try docs.bob.eventsSince(gpa, av2);
    defer gpa.free(batch2);
    switch (try gc.admitRegions(gpa, batch2)) {
        .refuse => |r| {
            defer r.free(gpa);
            try t.expectEqual(GraphCollab.RefusalReason.authority, r.reason);
        },
        .admit => return error.TestUnexpectedResult,
    }
}

test "subtree grant: create-and-populate a NEW child under the granted root in ONE batch is admitted (REQUIRED FIX 2)" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();

    var docs = try GrantDocs.setup(gpa);
    defer docs.deinit(gpa);

    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    var gc = try makeEnforcer(gpa, &docs, sp.a, &table);
    defer gc.deinit();
    _ = try gc.grantSubtree(docs.inside);

    // ONE local batch: the peer creates a NEW child under the granted root
    // AND immediately populates it — the ordinary shape of "grantee appends
    // an entry to its own subtree," the primary W6 use case. Before syncing
    // at all, this new node's `ObjId` exists ONLY in `docs.bob`'s history —
    // `docs.alice` (the enforcer's pre-merge replica) has never seen the
    // creating event, only the scratch clone `touchedRegionsWithin` builds
    // internally has.
    const b_inside = try docs.bob.resolve(docs.inside);
    const new_child = (try docs.bob.set(gpa, b_inside, "entry", .map)).?;
    _ = try docs.bob.set(gpa, new_child, "text", .{ .str = "hello" });
    const new_child_ref = try docs.bob.nodeRef(gpa, new_child);
    defer new_child_ref.free(gpa);

    const av = try docs.alice.version(gpa);
    defer gpa.free(av);
    const batch = try docs.bob.eventsSince(gpa, av);
    defer gpa.free(batch);

    // Pre-fix, this failed `self.doc.resolve` (MissingDependency) and was
    // refused `.authority` — PERMANENTLY, since the new node's identity
    // never becomes "older" on retry (see `admitRegions`'s doc comment on
    // why this broke "deferred-until-release, not a permanent verdict").
    switch (try gc.admitRegions(gpa, batch)) {
        .admit => {},
        .refuse => |r| {
            r.free(gpa);
            return error.TestUnexpectedResult;
        },
    }

    // Not just admitted in principle — it actually lands.
    const changes = try docs.alice.merge(gpa, batch);
    gpa.free(changes);
    const a_child = try docs.alice.resolve(new_child_ref);
    try t.expectEqualStrings("hello", docs.alice.ref(a_child).mapGet("text").?.asStr());
}

test "subtree grant: a peer with no grant rows of its own is unaffected — per-doc canEdit still governs" {
    const gpa = t.allocator;
    // Two DIFFERENT authenticated identities: the grant goes to the FIRST,
    // but the batch being checked is attributed (via `session`) to the
    // SECOND — zero rows for it.
    var sp_granted: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp_granted);
    defer sp_granted.deinit();
    var sp_other: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp_other);
    defer sp_other.deinit();

    var docs = try GrantDocs.setup(gpa);
    defer docs.deinit(gpa);

    var table = grants.HandleTable.init(gpa);
    defer table.deinit();

    // Alice's quad talking to the GRANTED identity mints the row...
    {
        var gc = try makeEnforcer(gpa, &docs, sp_granted.a, &table);
        defer gc.deinit();
        _ = try gc.grantSubtree(docs.inside);
    }

    // ...but THIS check runs on alice's quad talking to the OTHER
    // identity: absence of a grant row for THIS peer keeps today's
    // behavior (grants narrow, they don't default-deny the world).
    var gc = try makeEnforcer(gpa, &docs, sp_other.a, &table);
    defer gc.deinit();

    const b_outside = try docs.bob.resolve(docs.outside);
    _ = try docs.bob.set(gpa, b_outside, "k", .{ .str = "v" });
    const av = try docs.alice.version(gpa);
    defer gpa.free(av);
    const batch = try docs.bob.eventsSince(gpa, av);
    defer gpa.free(batch);

    switch (try gc.admitRegions(gpa, batch)) {
        .admit => {},
        .refuse => |r| {
            r.free(gpa);
            return error.TestUnexpectedResult;
        },
    }
}

test "subtree grant: root deleted — every subsequent admission traps loudly with the collapsed reason" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();

    var docs = try GrantDocs.setup(gpa);
    defer docs.deinit(gpa);

    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    var gc = try makeEnforcer(gpa, &docs, sp.a, &table);
    defer gc.deinit();
    _ = try gc.grantSubtree(docs.inside);

    // The subtree's root gets deleted on ALICE's replica — concurrently
    // with the peer's edit below (the peer never learns of the deletion
    // first).
    try docs.alice.unset(gpa, null, "inside");
    const inside_obj = try docs.alice.resolve(docs.inside);
    try t.expect(!try docs.alice.reachable(gpa, inside_obj));

    const b_inside = try docs.bob.resolve(docs.inside);
    _ = try docs.bob.set(gpa, b_inside, "k", .{ .str = "v" });
    const av = try docs.alice.version(gpa);
    defer gpa.free(av);
    const batch = try docs.bob.eventsSince(gpa, av);
    defer gpa.free(batch);

    switch (try gc.admitRegions(gpa, batch)) {
        .refuse => |r| {
            defer r.free(gpa);
            // The COLLAPSED reason, not a flat "authority" refusal — see
            // `GrantContext`'s doc comment: with the root gone, "you never
            // had access" would be dishonest (the peer DID, until it
            // collapsed); "re-grant needed" is the actionable signal.
            try t.expectEqual(GraphCollab.RefusalReason.collapsed, r.reason);
        },
        .admit => return error.TestUnexpectedResult,
    }
}

test "subtree grant + lease composition: inside the grant but leased by another -> lease refusal; outside the grant -> authority refusal" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();

    var docs = try GrantDocs.setup(gpa);
    defer docs.deinit(gpa);

    // A child node nested INSIDE the granted subtree — the lease half of
    // this test needs a region distinct from `inside` itself.
    const inside_obj = try docs.alice.resolve(docs.inside);
    const child_obj = (try docs.alice.set(gpa, inside_obj, "child", .map)).?;
    const child_ref = try docs.alice.nodeRef(gpa, child_obj);
    defer child_ref.free(gpa);

    // Sync bob up to the child's creation before he edits anything.
    {
        const bv = try docs.bob.version(gpa);
        defer gpa.free(bv);
        const batch = try docs.alice.eventsSince(gpa, bv);
        defer gpa.free(batch);
        const changes = try docs.bob.merge(gpa, batch);
        gpa.free(changes);
    }

    var grant_table = grants.HandleTable.init(gpa);
    defer grant_table.deinit();
    var lease_table: LeaseTable = .empty;
    defer lease_table.deinit(gpa);

    var gc = try makeEnforcer(gpa, &docs, sp.a, &grant_table);
    defer gc.deinit();
    gc.bindLeases(&lease_table);
    _ = try gc.grantSubtree(docs.inside);
    // Carol holds the child region's lease (occupancy, self-declared name
    // — leases stay name-keyed, only authority moved to identity) —
    // independent of the peer's (broader) authority over the whole
    // `inside` subtree.
    _ = try lease_table.tryAcquire(gpa, child_ref, "carol", 0);

    // The peer edits the CHILD: within its GRANT, but occupied by carol's
    // LEASE — a lease refusal, not an authority one (composition order:
    // authority passes first, THEN lease catches it).
    {
        const b_child = try docs.bob.resolve(child_ref);
        _ = try docs.bob.set(gpa, b_child, "k", .{ .str = "v" });
        const av = try docs.alice.version(gpa);
        defer gpa.free(av);
        const batch = try docs.bob.eventsSince(gpa, av);
        defer gpa.free(batch);
        switch (try gc.admitRegions(gpa, batch)) {
            .refuse => |r| {
                defer r.free(gpa);
                try t.expectEqual(GraphCollab.RefusalReason.lease, r.reason);
            },
            .admit => return error.TestUnexpectedResult,
        }
        // Test plumbing (see the confinement test's comment): advance
        // alice past this refused batch so the next check below is clean.
        const changes = try docs.alice.merge(gpa, batch);
        gpa.free(changes);
    }

    // The peer edits OUTSIDE the grant entirely: authority refusal,
    // distinct from the lease refusal above — the taxonomy is observable.
    {
        const b_outside = try docs.bob.resolve(docs.outside);
        _ = try docs.bob.set(gpa, b_outside, "k2", .{ .str = "v2" });
        const av = try docs.alice.version(gpa);
        defer gpa.free(av);
        const batch = try docs.bob.eventsSince(gpa, av);
        defer gpa.free(batch);
        switch (try gc.admitRegions(gpa, batch)) {
            .refuse => |r| {
                defer r.free(gpa);
                try t.expectEqual(GraphCollab.RefusalReason.authority, r.reason);
            },
            .admit => return error.TestUnexpectedResult,
        }
    }
}

test "subtree grant: a batch straddling the grant boundary is refused WHOLE, matching admitRegions' existing batch granularity" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();

    var docs = try GrantDocs.setup(gpa);
    defer docs.deinit(gpa);

    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    var gc = try makeEnforcer(gpa, &docs, sp.a, &table);
    defer gc.deinit();
    _ = try gc.grantSubtree(docs.inside);

    // ONE batch, two ops: one inside the grant, one outside it.
    const b_inside = try docs.bob.resolve(docs.inside);
    _ = try docs.bob.set(gpa, b_inside, "k1", .{ .str = "in" });
    const b_outside = try docs.bob.resolve(docs.outside);
    _ = try docs.bob.set(gpa, b_outside, "k2", .{ .str = "out" });

    const av = try docs.alice.version(gpa);
    defer gpa.free(av);
    const batch = try docs.bob.eventsSince(gpa, av);
    defer gpa.free(batch);

    switch (try gc.admitRegions(gpa, batch)) {
        .refuse => |r| {
            defer r.free(gpa);
            try t.expectEqual(GraphCollab.RefusalReason.authority, r.reason);
        },
        .admit => return error.TestUnexpectedResult,
    }

    // Whole-batch semantics: NEITHER op landed — a real driver's `.batch`
    // handler only ever calls `merge` on `.admit` (see this file's
    // `.batch` handler), and this test never called `merge` either.
    try t.expect(docs.alice.root().mapGet("inside").?.mapGet("k1") == null);
    try t.expect(docs.alice.root().mapGet("outside").?.mapGet("k2") == null);
}

test "subtree grant: confinement over the REAL wire (socketpair e2e) — admitted inside, refused loudly outside" {
    const gpa = t.allocator;
    var rig: LeaseRig = undefined;
    try LeaseRig.setup(gpa, &rig);
    defer rig.deinit(gpa);
    rig.bindLeases();

    var grant_table = grants.HandleTable.init(gpa);
    defer grant_table.deinit();
    rig.ga.bindGrants(&grant_table);

    // Alice (the host) grants bob's AUTHENTICATED identity — proven by the
    // secure handshake `LeaseRig.setup` already completed, `rig.ga.session
    // .peerFingerprint()` under the hood — authority over room1's subtree
    // only. No lease/name dance needed to establish identity anymore
    // (REQUIRED FIX 1: authority keys on the session, never a self-declared
    // name).
    _ = try rig.ga.grantSubtree(rig.room1);

    // Bob edits INSIDE the granted subtree (room1 itself, self-inclusive
    // containment) — admitted and lands on alice's replica.
    const b_room1 = try rig.joiner.resolve(rig.room1);
    _ = try rig.joiner.set(gpa, b_room1, "granted-edit", .{ .str = "ok" });
    {
        const deadline = task.nowNs() + 5 * std.time.ns_per_s;
        var landed = false;
        while (task.nowNs() < deadline) {
            try rig.pump();
            const a_room1 = rig.origin.resolve(rig.room1) catch continue;
            if (rig.origin.ref(a_room1).mapGet("granted-edit") != null) {
                landed = true;
                break;
            }
            testPark(2);
        }
        try t.expect(landed);
    }
    try t.expectEqual(@as(usize, 0), rig.gb.refusals.items.len);

    // Bob edits OUTSIDE the grant (room2) — refused loudly, authority
    // reason, never merged.
    const b_room2 = try rig.joiner.resolve(rig.room2);
    _ = try rig.joiner.set(gpa, b_room2, "denied-edit", .{ .str = "no" });
    {
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
    }
    try t.expectEqual(@as(usize, 1), rig.gb.refusals.items.len);
    try t.expectEqual(GraphCollab.RefusalReason.authority, rig.gb.refusals.items[0].reason);
    try t.expect(rig.origin.ref(rig.origin.resolve(rig.room2) catch unreachable).mapGet("denied-edit") == null);
}

// ── D3 — stuck-authority-refusal PREVENTION + RECOVERY (task #24,
// doc/substrate.md §5, in full: "how a stuck replica recovers, and —
// more importantly — how the stuck state is made unreachable in the first
// place"). The seven falsifiable tests from that doc's §6, in order:
// two TRACE LOCKS guarding the dead designs (§1.1/§1.2's findings against
// regression), two PREVENTION tests (the graph `.grant` announce +
// `GraphCollab.mayEditNode` pre-flight), one RECOVERY test (the
// re-bootstrap that heals a replica already poisoned by the W6 check-in
// test's own negative case), one TRIGGER-HONESTY test (the "wait for
// release" path is proven dead for authority), and one showing collapse
// composes with the same recovery path. Reuses this file's existing rigs
// (`SessionPair`/`GrantDocs`/`makeEnforcer` for deterministic direct-mint
// checks, `LeaseRig` for a real wire pump, and a bespoke detach/re-attach
// for the recovery test — the SAME pattern the W6 check-in test's stage 4
// already proves, extended here to also discard and rebuild the poisoned
// `GraphDoc` itself).

test "D3 §6 test 1 (trace lock, falsifies design #1): revert-in-same-batch (insert then delete netting zero) is STILL refused .authority — a region is reported for every APPLIED change, never net content" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();

    var docs = try GrantDocs.setup(gpa);
    defer docs.deinit(gpa);

    // A text object OUTSIDE the grant, seeded on alice then synced to bob
    // BEFORE the grant is declared — the revert edit below needs an
    // existing text object to insert-then-delete on.
    const a_outside = try docs.alice.resolve(docs.outside);
    const text_obj = (try docs.alice.set(gpa, a_outside, "body", .text)).?;
    const text_ref = try docs.alice.nodeRef(gpa, text_obj);
    defer text_ref.free(gpa);
    {
        const bv = try docs.bob.version(gpa);
        defer gpa.free(bv);
        const batch = try docs.alice.eventsSince(gpa, bv);
        defer gpa.free(batch);
        const changes = try docs.bob.merge(gpa, batch);
        gpa.free(changes);
    }

    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    var gc = try makeEnforcer(gpa, &docs, sp.a, &table);
    defer gc.deinit();
    _ = try gc.grantSubtree(docs.inside);

    // Bob (out-of-grant) inserts then deletes the SAME bytes, in ONE local
    // batch — nets zero visible content, but both the insert and the
    // delete are real, applied `Change`s naming the out-of-grant text
    // object (doc/substrate.md §5: coalescing an insert+delete
    // pair does NOT fold to nothing, and even when adjacent same-direction
    // edits DO coalesce, the change still carries the object).
    const b_text = try docs.bob.resolve(text_ref);
    _ = try docs.bob.textInsert(gpa, b_text, 0, "XY");
    _ = try docs.bob.textDelete(gpa, b_text, .{ .start = 0, .end = 2 });

    const av = try docs.alice.version(gpa);
    defer gpa.free(av);
    const batch = try docs.bob.eventsSince(gpa, av);
    defer gpa.free(batch);

    switch (try gc.admitRegions(gpa, batch)) {
        .refuse => |r| {
            defer r.free(gpa);
            try t.expectEqual(GraphCollab.RefusalReason.authority, r.reason);
        },
        .admit => return error.TestUnexpectedResult,
    }
    // Never merged — home's replica is byte-for-byte unchanged: the
    // "revert" bought nothing, exactly as §1.1 traces.
    try t.expectEqual(@as(usize, 0), docs.alice.ref(text_obj).textRope().byteLen());
}

test "D3 §6 test 2 (trace lock, falsifies design #2): a straddling batch is refused WHOLE, and re-riding the UNCHANGED batch never partially admits the in-grant op" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();

    var docs = try GrantDocs.setup(gpa);
    defer docs.deinit(gpa);

    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    var gc = try makeEnforcer(gpa, &docs, sp.a, &table);
    defer gc.deinit();
    _ = try gc.grantSubtree(docs.inside);

    // ONE batch, two ops: one inside the grant, one outside it — same
    // shape as the "straddling" test above.
    const b_inside = try docs.bob.resolve(docs.inside);
    _ = try docs.bob.set(gpa, b_inside, "k1", .{ .str = "in" });
    const b_outside = try docs.bob.resolve(docs.outside);
    _ = try docs.bob.set(gpa, b_outside, "k2", .{ .str = "out" });

    const av = try docs.alice.version(gpa);
    defer gpa.free(av);
    const batch = try docs.bob.eventsSince(gpa, av);
    defer gpa.free(batch);

    // Re-check the IDENTICAL batch bytes N times — standing in for "the
    // sender keeps re-offering it every tick" (`sync_core`'s frontier-delta
    // re-includes an unmerged op forever, §0 finding #1: alice never merges
    // on a `.refuse`, so her version never advances, so a real re-send
    // would compute this exact same delta every time). If op-subset
    // admission existed on this substrate (design #2), SOME retry would
    // eventually admit "k1" alone; per-agent run contiguity
    // (`ObjectDoc.Decoder.validate`, §1.2) forbids it, so EVERY retry
    // refuses the batch WHOLE, identically.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        switch (try gc.admitRegions(gpa, batch)) {
            .refuse => |r| {
                defer r.free(gpa);
                try t.expectEqual(GraphCollab.RefusalReason.authority, r.reason);
            },
            .admit => return error.TestUnexpectedResult,
        }
    }

    // Neither op ever landed — not "k2" (expected, out-of-grant), and
    // critically not "k1" EITHER (in-grant, but bundled): the letter of
    // "no partial admit path exists."
    try t.expect(docs.alice.root().mapGet("inside").?.mapGet("k1") == null);
    try t.expect(docs.alice.root().mapGet("outside").?.mapGet("k2") == null);
}

test "D3 §6 test 3 (prevention): an announced subtree grant reaches the grantee via the graph .grant frame, and the client's own pre-flight check refuses an out-of-grant edit LOCALLY — never minted, never sent, never refused by the host" {
    const gpa = t.allocator;
    var rig: LeaseRig = undefined;
    try LeaseRig.setup(gpa, &rig);
    defer rig.deinit(gpa);

    var grant_table = grants.HandleTable.init(gpa);
    defer grant_table.deinit();
    rig.ga.bindGrants(&grant_table);
    _ = try rig.ga.grantSubtree(rig.room1);

    // Pump until bob's quad has recorded the announced root over the graph
    // `.grant` frame — the prevention half landing.
    const deadline = task.nowNs() + 5 * std.time.ns_per_s;
    var announced = false;
    while (task.nowNs() < deadline) {
        try rig.pump();
        if (rig.gb.granted_roots.len == 1 and rig.gb.granted_roots[0].eql(rig.room1)) {
            announced = true;
            break;
        }
        testPark(2);
    }
    try t.expect(announced);
    try t.expectEqual(@as(usize, 0), rig.gb.refusals.items.len); // nothing refused yet

    // Pre-flight: bob's own local predicate, against his own LIVE doc —
    // in-grant admits, out-of-grant refuses.
    const room1_obj = try rig.joiner.resolve(rig.room1);
    const room2_obj = try rig.joiner.resolve(rig.room2);
    try t.expect(try rig.gb.mayEditNode(gpa, room1_obj));
    try t.expect(!(try rig.gb.mayEditNode(gpa, room2_obj)));

    // The honest client discipline this predicate exists to support
    // (doc/substrate.md §5's "before committing the local op AND before
    // it can ride a batch"): consult it BEFORE minting anything.
    // In-grant: the check passes, the edit is minted, sent, and
    // admitted.
    _ = try rig.joiner.set(gpa, room1_obj, "granted-edit", .{ .str = "ok" });
    {
        const land_deadline = task.nowNs() + 5 * std.time.ns_per_s;
        var landed = false;
        while (task.nowNs() < land_deadline) {
            try rig.pump();
            const a_room1 = rig.origin.resolve(rig.room1) catch continue;
            if (rig.origin.ref(a_room1).mapGet("granted-edit") != null) {
                landed = true;
                break;
            }
            testPark(2);
        }
        try t.expect(landed);
    }

    // Out-of-grant: the check FAILS, so the honest client never calls
    // `joiner.set` at all — no op is ever minted (D3 §2.1: "no out-of-grant
    // event is ever minted"), so nothing is ever sent, nothing is ever
    // refused, and the host never even sees an attempt.
    const quiescent_deadline = task.nowNs() + 200 * std.time.ns_per_ms;
    while (task.nowNs() < quiescent_deadline) {
        try rig.pump();
        testPark(2);
    }
    try t.expectEqual(@as(usize, 0), rig.gb.refusals.items.len);
    try t.expect(rig.origin.ref(rig.origin.resolve(rig.room2) catch unreachable).mapGet("denied-edit") == null);
}

test "D3 §6 test 4 (prevention is advisory only — cannot widen): a grantee's local belief in a wider grant still can't get an out-of-grant op merged" {
    const gpa = t.allocator;
    var rig: LeaseRig = undefined;
    try LeaseRig.setup(gpa, &rig);
    defer rig.deinit(gpa);

    var grant_table = grants.HandleTable.init(gpa);
    defer grant_table.deinit();
    rig.ga.bindGrants(&grant_table);
    _ = try rig.ga.grantSubtree(rig.room1); // room2 is NEVER granted

    // Simulate a grantee that OVER-CLAIMS: its local `granted_roots`
    // (DISPLAY/prevention state — never authority) claims BOTH rooms,
    // wider than what alice's table actually holds — either because it
    // ignored the real announcement or because it was fed (a buggy host,
    // or a MITM) a claim wider than the host's table. Constructed directly
    // rather than over the wire (same technique the "SPOOFED peer_name"
    // test above uses to bypass the wire and assert straight against the
    // adversarial belief).
    var roots: std.ArrayList(GraphDoc.NodeRef) = .empty;
    defer roots.deinit(gpa);
    try roots.append(gpa, try rig.room1.dupe(gpa));
    try roots.append(gpa, try rig.room2.dupe(gpa));
    rig.gb.granted_roots = try roots.toOwnedSlice(gpa); // freed by rig.deinit -> gb.deinit

    // The local predicate, fooled by the over-claim, says room2 is fine...
    const room2_obj = try rig.joiner.resolve(rig.room2);
    try t.expect(try rig.gb.mayEditNode(gpa, room2_obj));

    // ...but sending the edit anyway (bypassing the local check, as a
    // buggy/malicious client would) still gets refused: the announcement
    // is advisory, never authority — the HOST's `admitRegions` is the only
    // real enforcement, independent of whatever the grantee believes.
    _ = try rig.joiner.set(gpa, room2_obj, "denied-edit", .{ .str = "no" });
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
    try t.expectEqual(GraphCollab.RefusalReason.authority, rig.gb.refusals.items[0].reason);
    try t.expect(rig.origin.ref(rig.origin.resolve(rig.room2) catch unreachable).mapGet("denied-edit") == null);
}

test "D3 §6 test 5 (recovery): re-bootstrap heals a poisoned replica — frontiers converge, the in-grant edit lands, the out-of-grant edit never does, home's other region is undisturbed" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };

    var origin = try GraphDoc.init(gpa, "alice");
    defer origin.deinit(gpa);
    const inside_obj = (try origin.set(gpa, null, "inside", .map)).?;
    const outside_obj = (try origin.set(gpa, null, "outside", .map)).?;
    const inside_ref = try origin.nodeRef(gpa, inside_obj);
    defer inside_ref.free(gpa);
    const outside_ref = try origin.nodeRef(gpa, outside_obj);
    defer outside_ref.free(gpa);
    // Home's OTHER region — must survive the whole scenario untouched
    // (property iv: "the host's stream/other regions were never
    // disturbed").
    _ = try origin.set(gpa, outside_obj, "untouched", .{ .str = "home" });

    // The remote's PERSISTENT identity, reused across the re-attach below —
    // same discipline the W6 check-in test's stage 4 established: a
    // reconnecting peer authenticating with the SAME keypair is,
    // structurally, the SAME grantee, so the standing grant survives with
    // no re-grant call.
    const remote_id = identity.Identity.forTest(0xd3);

    var sa = try Session.create(gpa, la.link(), .server, "tok", .own, null);
    const sb1 = try Session.create(gpa, lb.link(), .client, "tok", .own, &remote_id);
    var ca = try Conn.init(gpa, sa, "home", .server);
    defer ca.deinit();
    var cb1 = try Conn.init(gpa, sb1, "remote", .client);

    const ga = try ca.shareGraph(&origin, "d3-recover", 1);

    const offer_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < offer_deadline and cb1.offers.items.len == 0) {
        _ = try ca.tick();
        _ = try cb1.tick();
        futexWaitTimed(&sa.out_wake, sa.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(cb1.offers.items.len > 0);

    var remote1 = try GraphDoc.init(gpa, "remote");
    const gb1 = try cb1.openGraphOffer(0, &remote1, 1);

    const bootstrap_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < bootstrap_deadline and remote1.root().mapGet("inside") == null) {
        _ = try ca.tick();
        _ = try cb1.tick();
        futexWaitTimed(&sb1.out_wake, sb1.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(remote1.root().mapGet("inside") != null);

    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    ga.bindGrants(&table);
    _ = try ga.grantSubtree(inside_ref);

    // ── Drive the poison: an out-of-grant edit is refused, then a
    // SUBSEQUENT in-grant edit is refused TOO — by bundling with the
    // still-unmerged refusal (the W6 check-in test's own negative case;
    // doc/substrate.md §5's "the refuser's frontier never
    // advances past the refused op"). ──
    const b1_outside = try remote1.resolve(outside_ref);
    _ = try remote1.set(gpa, b1_outside, "poison", .{ .str = "bad" });

    const poison_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < poison_deadline and gb1.refusals.items.len == 0) {
        _ = try ca.tick();
        _ = try cb1.tick();
        testPark(2);
    }
    try t.expect(gb1.refusals.items.len > 0);
    try t.expectEqual(GraphCollab.RefusalReason.authority, gb1.refusals.items[0].reason);
    // The trigger-honesty predicate: this is the client's signal to
    // re-bootstrap, not to wait.
    try t.expect(gb1.needsRebootstrap());

    const b1_inside = try remote1.resolve(inside_ref);
    _ = try remote1.set(gpa, b1_inside, "wanted", .{ .str = "good" });

    const stuck_deadline = task.nowNs() + 3 * std.time.ns_per_s;
    while (task.nowNs() < stuck_deadline and gb1.refusals.items.len < 2) {
        _ = try ca.tick();
        _ = try cb1.tick();
        testPark(2);
    }
    try t.expect(gb1.refusals.items.len >= 2); // the in-grant edit got bundled and refused too
    try t.expect(origin.ref(inside_obj).mapGet("wanted") == null); // permanently stuck, absent recovery

    // ── Recovery (§2.2/§1.3): discard the poisoned replica, re-attach with
    // a fresh `GraphDoc` + a fresh `GraphCollab` (a brand-new `Conn`), on
    // the SAME persistent identity — the empty-joiner bootstrap pulls
    // home's CLEAN history (which never merged the poison). ──
    cb1.deinit(); // frees gb1 too
    sb1.destroy();
    sa.destroy();

    const fds2 = try socketPair();
    var la2: FdLink = .{ .fd = fds2[0] };
    var lb2: FdLink = .{ .fd = fds2[1] };
    sa = try Session.create(gpa, la2.link(), .server, "tok", .own, null);
    defer sa.destroy();
    const sb2 = try Session.create(gpa, lb2.link(), .client, "tok", .own, &remote_id);
    defer sb2.destroy();
    try ca.rebind(sa); // re-announces ga's share to whoever attaches next

    var cb2 = try Conn.init(gpa, sb2, "remote", .client);
    defer cb2.deinit();

    remote1.deinit(gpa); // discard the poisoned replica

    const reoffer_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < reoffer_deadline and cb2.offers.items.len == 0) {
        _ = try ca.tick();
        _ = try cb2.tick();
        futexWaitTimed(&sa.out_wake, sa.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(cb2.offers.items.len > 0);

    var remote2 = try GraphDoc.init(gpa, "remote");
    defer remote2.deinit(gpa);
    const gb2 = try cb2.openGraphOffer(0, &remote2, 1);

    const rebootstrap_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < rebootstrap_deadline and remote2.root().mapGet("inside") == null) {
        _ = try ca.tick();
        _ = try cb2.tick();
        futexWaitTimed(&sb2.out_wake, sb2.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(remote2.root().mapGet("inside") != null);
    // The fresh replica pulled home's CLEAN history — it never saw the
    // poison, so it starts from exactly what home has right now.
    try t.expect(remote2.root().mapGet("outside").?.mapGet("poison") == null);

    // Replay ONLY the still-wanted, in-grant edit, as a fresh local event
    // on the clean base — the grant survives the reconnect (identity-
    // keyed), so no second `grantSubtree` call is needed.
    const b2_inside = try remote2.resolve(inside_ref);
    _ = try remote2.set(gpa, b2_inside, "wanted", .{ .str = "good" });

    const land_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    var landed = false;
    while (task.nowNs() < land_deadline) {
        _ = try ca.tick();
        _ = try cb2.tick();
        if (origin.ref(inside_obj).mapGet("wanted") != null) {
            landed = true;
            break;
        }
        testPark(2);
    }
    try t.expect(landed); // (ii) the in-grant edit landed on home

    // (i) frontiers converge — not just content agreement.
    {
        const hv = try origin.version(gpa);
        defer gpa.free(hv);
        const rv = try remote2.version(gpa);
        defer gpa.free(rv);
        try t.expectEqual(GraphDoc.VersionOrder.equal, try origin.compareVersions(gpa, hv, rv));
    }
    // (iii) the out-of-grant edit never landed, even after recovery.
    try t.expect(origin.ref(outside_obj).mapGet("poison") == null);
    // (iv) home's OTHER region was never disturbed.
    try t.expectEqualStrings("home", origin.ref(outside_obj).mapGet("untouched").?.asStr());
    try t.expectEqualStrings("good", origin.ref(inside_obj).mapGet("wanted").?.asStr());
    // The replayed edit was clean — no refusal on the fresh replica.
    try t.expectEqual(@as(usize, 0), gb2.refusals.items.len);
}

test "D3 §6 test 6 (trigger honesty): an .authority refusal is the signal to re-bootstrap, and the wait-for-release path is proven dead after N ticks" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();

    var docs = try GrantDocs.setup(gpa);
    defer docs.deinit(gpa);

    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    var gc = try makeEnforcer(gpa, &docs, sp.a, &table);
    defer gc.deinit();
    _ = try gc.grantSubtree(docs.inside);

    const b_outside = try docs.bob.resolve(docs.outside);
    _ = try docs.bob.set(gpa, b_outside, "k", .{ .str = "v" });
    const av = try docs.alice.version(gpa);
    defer gpa.free(av);
    const batch = try docs.bob.eventsSince(gpa, av);
    defer gpa.free(batch);

    // "No release ever arrives, and nothing proactively retries" —
    // simulated as N re-checks of the SAME unmerged batch, standing in for
    // N ticks of a sender that keeps re-offering it (`sync_core`'s
    // frontier-delta) with nothing changing on the enforcer's side (there
    // IS no lease to release here — this is authority). Every single one
    // refuses identically: the "deferred-until-release" healing property a
    // LEASE gets NEVER fires for authority.
    const N = 25;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        switch (try gc.admitRegions(gpa, batch)) {
            .refuse => |r| {
                defer r.free(gpa);
                try t.expectEqual(GraphCollab.RefusalReason.authority, r.reason);
            },
            .admit => return error.TestUnexpectedResult, // would falsify "the wait path is dead"
        }
    }
    // Still never merged, after all N "ticks."
    try t.expect(docs.alice.root().mapGet("outside").?.mapGet("k") == null);

    // The sender's own signal (`refusals`, appended by the real wire path
    // when the echoed `.region_refused` lands — simulated directly here,
    // same technique the other direct-mint tests in this suite use to
    // exercise `GraphCollab` state without a socket) names the reason as
    // `.authority`, and `needsRebootstrap` reads it as the policy trigger.
    var sender = try GraphCollab.init(gpa, undefined, &docs.bob, "bob");
    defer sender.deinit();
    try t.expect(!sender.needsRebootstrap()); // nothing refused yet — no trigger
    try sender.refusals.append(gpa, .{
        .region = try docs.outside.dupe(gpa),
        .holder = try gpa.dupe(u8, ""),
        .reason = .authority,
    });
    // The policy: an authority (or collapsed) refusal is a re-bootstrap
    // trigger, never a "wait for release" one — `.lease` is the ONLY
    // refusal reason that ever heals by waiting.
    try t.expect(sender.needsRebootstrap());
}

test "D3 §6 test 7 (collapse composes with recovery): a sole grant root's collapse refuses .collapsed, and the SAME re-bootstrap path heals it" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();

    var docs = try GrantDocs.setup(gpa);
    defer docs.deinit(gpa);

    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    var gc = try makeEnforcer(gpa, &docs, sp.a, &table);
    defer gc.deinit();
    _ = try gc.grantSubtree(docs.inside); // bob's SOLE grant root

    // The root collapses on alice's replica (deleted) — concurrently with
    // bob's edit, exactly like the existing "root deleted" test above.
    try docs.alice.unset(gpa, null, "inside");
    const inside_obj = try docs.alice.resolve(docs.inside);
    try t.expect(!try docs.alice.reachable(gpa, inside_obj));

    const b_inside = try docs.bob.resolve(docs.inside);
    _ = try docs.bob.set(gpa, b_inside, "ungrounded", .{ .str = "orphaned" });
    const av = try docs.alice.version(gpa);
    defer gpa.free(av);
    const batch = try docs.bob.eventsSince(gpa, av);
    defer gpa.free(batch);

    switch (try gc.admitRegions(gpa, batch)) {
        .refuse => |r| {
            defer r.free(gpa);
            try t.expectEqual(GraphCollab.RefusalReason.collapsed, r.reason);
        },
        .admit => return error.TestUnexpectedResult,
    }
    // Bob's edit applied locally (as every refused send does) but never
    // reached alice — checked against the collapsed object DIRECTLY (its
    // creating event is permanent history, so it stays readable even
    // though it's unreachable from `root()` now; `root().mapGet("inside")`
    // is `null` post-collapse, so that path can't be used to check this).
    try t.expect(docs.alice.ref(inside_obj).mapGet("ungrounded") == null);

    // ── Recovery: the SAME re-bootstrap path (§2.2/§1.3) heals a
    // collapsed-grant poison exactly like an authority one — discard bob's
    // replica, open a fresh one from alice's CURRENT (post-collapse)
    // history. Bob has nothing left to re-apply: the grant's root is gone,
    // so per `GrantContext`'s doc comment ("a grantee with a dead grant has
    // no OTHER standing to edit with"), there is no still-meaningful edit
    // to replay — the honest outcome of a sole grant collapsing. ──
    docs.bob.deinit(gpa);
    const alice_bytes = try docs.alice.serialize(gpa);
    defer gpa.free(alice_bytes);
    docs.bob = try GraphDoc.open(gpa, "bob", alice_bytes);

    // Converges to home's post-collapse state, byte for byte — frontier
    // equality, not just content agreement.
    {
        const hv = try docs.alice.version(gpa);
        defer gpa.free(hv);
        const rv = try docs.bob.version(gpa);
        defer gpa.free(rv);
        try t.expectEqual(GraphDoc.VersionOrder.equal, try docs.alice.compareVersions(gpa, hv, rv));
    }
    // None of the now-ungrounded edit survived recovery.
    try t.expect(docs.bob.root().mapGet("inside") == null);
}

// ── W7b — THE FLAGSHIP GATE (doc/substrate.md §9): a function-level
// subtree grant on a CODE buffer, keyed by node identity, surviving a
// peer's concurrent in-function edit AND a peer's move/reorder of the
// function, OR trapping loudly on its deletion.
//
// "Code buffer" here is a `GraphDoc` reconciled by `syntax_claim.reconcile`
// (W7b piece 2) into one struct node per function, each owning its OWN
// `"body"` text object (see `syntax_claim.zig`'s module doc comment for
// why that decouples "where a function sits" from "what it contains," and
// hence why a move can never collapse anything here). The admission
// machinery below is 100% the EXISTING, already-shipped W6 slice 2
// mechanism (`GraphCollab.grantSubtree`/`admitRegions`) — piece 1
// (`graph.zig`'s struct-forest-aware `contains`/`reachable` and the
// move-admission rule in `touchedRegionsWithin`) is what makes it correct
// for struct nodes; nothing new is built here, only wired and exercised.
//
// A lighter rig than `LeaseRig`'s full socketpair `Conn` wire (same choice
// the "peer confined to a granted subtree" test above makes): a real
// `SessionPair` for authenticated identity (`admitRegions` only ever calls
// `session.peerFingerprint()`, never anything wire-shaped), batch bytes
// moved by hand via `eventsSince`/`admitRegions`/`merge` — deterministic,
// no timing-dependent `pump`/deadline loop to flake (see
// [[flakes-are-real-bugs]]: a timing flake on a fast box is a real bug,
// avoided here by construction rather than budgeted for).

/// Two docs sharing a code buffer reconciled into three functions
/// (`helperA`, `functionB`, `helperC`) — `functionB` is the one a grant
/// will confine a peer to.
const SyntaxGateDocs = struct {
    alice: GraphDoc,
    bob: GraphDoc,
    a_ref: GraphDoc.NodeRef,
    b_ref: GraphDoc.NodeRef,
    c_ref: GraphDoc.NodeRef,

    const source =
        \\const std = @import("std");
        \\
        \\fn helperA() void {
        \\    doA();
        \\}
        \\
        \\pub fn functionB(x: i32) i32 {
        \\    return x + 1;
        \\}
        \\
        \\fn helperC() void {
        \\    doC();
        \\}
        \\
    ;

    fn setup(gpa: Allocator) !SyntaxGateDocs {
        var alice = try GraphDoc.init(gpa, "alice");
        errdefer alice.deinit(gpa);
        // `res.created` is OWNED (freed by `deinit` below); `res.kept`/
        // `.deleted` are plain counts, nothing to free — see
        // `ReconcileResult`'s field docs.
        var res = try syntax_claim.reconcile(gpa, &alice, source);
        defer res.deinit(gpa);
        try t.expectEqual(@as(usize, 3), res.created.items.len);

        const a_ref = (try syntax_claim.findByName(gpa, &alice, "helperA")).?;
        errdefer a_ref.free(gpa);
        const b_ref = (try syntax_claim.findByName(gpa, &alice, "functionB")).?;
        errdefer b_ref.free(gpa);
        const c_ref = (try syntax_claim.findByName(gpa, &alice, "helperC")).?;
        errdefer c_ref.free(gpa);

        const bytes = try alice.serialize(gpa);
        defer gpa.free(bytes);
        var bob = try GraphDoc.open(gpa, "bob", bytes);
        errdefer bob.deinit(gpa);

        return .{ .alice = alice, .bob = bob, .a_ref = a_ref, .b_ref = b_ref, .c_ref = c_ref };
    }

    fn deinit(self: *SyntaxGateDocs, gpa: Allocator) void {
        self.a_ref.free(gpa);
        self.b_ref.free(gpa);
        self.c_ref.free(gpa);
        self.alice.deinit(gpa);
        self.bob.deinit(gpa);
    }
};

/// Admit `batch` through `gc`, merge it into `docs.alice` if admitted, and
/// fail the test loudly on refusal — the "should always land" shape parts
/// (a)/(b) of the gate share.
fn admitAndMerge(gpa: Allocator, gc: *GraphCollab, docs: *SyntaxGateDocs, batch: []const u8) !void {
    switch (try gc.admitRegions(gpa, batch)) {
        .admit => {},
        .refuse => |r| {
            r.free(gpa);
            return error.TestUnexpectedResult;
        },
    }
    const changes = try docs.alice.merge(gpa, batch);
    gpa.free(changes);
}

test "W7b gate: function-level subtree grant survives a concurrent in-function edit (a), a host MOVE of the function (b), and traps loudly on host DELETE (c)" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();

    var docs = try SyntaxGateDocs.setup(gpa);
    defer docs.deinit(gpa);

    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    var gc = try GraphCollab.init(gpa, sp.a, &docs.alice, "codebuf");
    defer gc.deinit();
    gc.bindGrants(&table);

    // The host grants the peer's AUTHENTICATED identity authority over
    // `functionB`'s subtree ONLY — nothing about helperA/helperC.
    _ = try gc.grantSubtree(docs.b_ref);

    const alice_b = try docs.alice.resolve(docs.b_ref);
    const alice_b_body = syntax_claim.bodyOf(&docs.alice, alice_b).?;
    const bob_b = try docs.bob.resolve(docs.b_ref);
    const bob_b_body = syntax_claim.bodyOf(&docs.bob, bob_b).?;
    const alice_a = try docs.alice.resolve(docs.a_ref);
    const alice_a_body = syntax_claim.bodyOf(&docs.alice, alice_a).?;

    // ── (a) the peer edits INSIDE functionB, CONCURRENTLY with the host
    // editing elsewhere (helperA's own body, never granted) — the peer's
    // edit is admitted (subtree containment: functionB's body is a direct
    // child of functionB's own struct node), the host's edit needs no
    // admission at all (it's the host's own replica), and both converge —
    // disjoint objects, D1 §3 case 1.
    _ = try docs.alice.textInsert(gpa, alice_a_body, 0, "// host edit elsewhere\n");
    _ = try docs.bob.textInsert(gpa, bob_b_body, 0, "// peer edit\n");
    {
        const av = try docs.alice.version(gpa);
        defer gpa.free(av);
        const batch = try docs.bob.eventsSince(gpa, av);
        defer gpa.free(batch);
        try admitAndMerge(gpa, &gc, &docs, batch);
    }
    try t.expectEqual(@as(usize, 0), gc.refusals.items.len);
    // Sync alice's own edit back to bob too, then assert full convergence.
    {
        const bv = try docs.bob.version(gpa);
        defer gpa.free(bv);
        const batch = try docs.alice.eventsSince(gpa, bv);
        defer gpa.free(batch);
        const changes = try docs.bob.merge(gpa, batch);
        gpa.free(changes);
    }
    {
        const av = try docs.alice.version(gpa);
        defer gpa.free(av);
        const bv = try docs.bob.version(gpa);
        defer gpa.free(bv);
        try t.expectEqual(GraphDoc.VersionOrder.equal, try docs.alice.compareVersions(gpa, av, bv));
    }
    {
        const body_bytes = try docs.alice.ref(alice_b_body).textRope().toOwnedSlice(gpa);
        defer gpa.free(body_bytes);
        try t.expect(std.mem.indexOf(u8, body_bytes, "peer edit") != null);
    }
    {
        const a_body_obj = syntax_claim.bodyOf(&docs.bob, try docs.bob.resolve(docs.a_ref)).?;
        const bytes = try docs.bob.ref(a_body_obj).textRope().toOwnedSlice(gpa);
        defer gpa.free(bytes);
        try t.expect(std.mem.indexOf(u8, bytes, "host edit elsewhere") != null);
    }

    // ── (b) the HOST MOVES functionB: reparented under helperA's OWN
    // struct node — a real structural move (not a cosmetic reorder),
    // exercising piece 1's nested struct-forest containment too. An
    // anchor-pair grant (doc/substrate.md §1) could not survive this AT ALL
    // (a move in a shared-buffer model is a cut+paste, minting new
    // insertion identity and collapsing the pair) — here NOTHING about
    // functionB's own `ObjId` or its `"body"` object changes, so the
    // grant (keyed on functionB's `NodeRef`) needs no re-issue, and the
    // peer doesn't even need to learn about the move to keep editing.
    {
        const key = try GraphDoc.orderKeyBetween(gpa, null, null);
        defer gpa.free(key);
        try docs.alice.structMove(gpa, alice_b, .{ .node = alice_a }, key);
    }
    switch (docs.alice.structParent(alice_b).?) {
        .node => |p| try t.expectEqual(alice_a, p),
        .root, .trash => return error.TestUnexpectedResult,
    }

    _ = try docs.bob.textInsert(gpa, bob_b_body, 0, "// peer edit after move\n");
    {
        const av = try docs.alice.version(gpa);
        defer gpa.free(av);
        const batch = try docs.bob.eventsSince(gpa, av);
        defer gpa.free(batch);
        try admitAndMerge(gpa, &gc, &docs, batch);
    }
    try t.expectEqual(@as(usize, 0), gc.refusals.items.len);
    {
        const body_bytes = try docs.alice.ref(alice_b_body).textRope().toOwnedSlice(gpa);
        defer gpa.free(body_bytes);
        try t.expect(std.mem.indexOf(u8, body_bytes, "peer edit after move") != null);
    }

    // ── (c) the HOST DELETES functionB (`structDelete` — moves it to
    // `.trash`). The peer's grant COLLAPSES: `functionB`'s `NodeRef` no
    // longer resolves-`reachable` (piece 1's `reachable`, which now knows
    // the struct forest), so `gatherGrantRoots` excludes it from the
    // peer's usable roots — it was the peer's ONLY grant, so admission
    // refuses EVERYTHING for this peer on this doc, loudly, `.collapsed`
    // — never silently admitted, never silently dropped.
    try docs.alice.structDelete(gpa, alice_b);
    try t.expect(!try docs.alice.reachable(gpa, alice_b));

    _ = try docs.bob.textInsert(gpa, bob_b_body, 0, "// peer edit after delete\n");
    {
        const av = try docs.alice.version(gpa);
        defer gpa.free(av);
        const batch = try docs.bob.eventsSince(gpa, av);
        defer gpa.free(batch);
        switch (try gc.admitRegions(gpa, batch)) {
            .refuse => |r| {
                defer r.free(gpa);
                try t.expectEqual(GraphCollab.RefusalReason.collapsed, r.reason);
            },
            .admit => return error.TestUnexpectedResult,
        }
    }
    {
        const body_bytes = try docs.alice.ref(alice_b_body).textRope().toOwnedSlice(gpa);
        defer gpa.free(body_bytes);
        try t.expect(std.mem.indexOf(u8, body_bytes, "peer edit after delete") == null); // never merged
    }
}

test "W7b gate: an in-node identity anchor inside a granted function's body survives a concurrent edit — names the CHARACTER, not the offset" {
    const gpa = t.allocator;
    var docs = try SyntaxGateDocs.setup(gpa);
    defer docs.deinit(gpa);

    const bob_b = try docs.bob.resolve(docs.b_ref);
    const bob_b_body = syntax_claim.bodyOf(&docs.bob, bob_b).?;

    const orig_bytes = try docs.bob.ref(bob_b_body).textRope().toOwnedSlice(gpa);
    defer gpa.free(orig_bytes);
    const anchor_off: usize = 10;
    try t.expect(orig_bytes.len > anchor_off);
    const target_char = orig_bytes[anchor_off];

    const anchor = try docs.bob.objectAnchorAt(gpa, bob_b_body, anchor_off, .before);
    defer gpa.free(anchor.agent);

    // A concurrent in-function edit — exactly what a peer holding a
    // subtree grant on functionB, or a collaborator sharing it, sends —
    // inserted BEFORE the anchored position, shifting every byte offset
    // from there on.
    const prefix = "// concurrent edit\n";
    _ = try docs.bob.textInsert(gpa, bob_b_body, 0, prefix);

    var resolved: [1]usize = undefined;
    try docs.bob.resolveObjectAnchors(gpa, bob_b_body, &.{anchor}, &resolved);

    // The NUMERIC offset shifted by exactly the inserted prefix's length —
    // if it named a fixed OFFSET, resolving would incorrectly still
    // report `anchor_off`. It names the CHARACTER instead.
    try t.expectEqual(anchor_off + prefix.len, resolved[0]);
    const new_bytes = try docs.bob.ref(bob_b_body).textRope().toOwnedSlice(gpa);
    defer gpa.free(new_bytes);
    try t.expectEqual(target_char, new_bytes[resolved[0]]);
}

// ── W7b move-admission coverage (post-review) — the entire structural
// admission path (`structuralChangeAdmitted`, `graph.zig`) had ZERO tests
// before this: no peer batch anywhere in the suite ever carried a
// `.structure` change through `admitRegions`. That is why the first
// version's rule shipped with a real hole (review found it: node-and-
// destination-only admits an ADOPT-IN — a peer moving a FOREIGN node to
// become a child of their own granted root, escalating a narrow grant to
// the whole document). The five tests below exercise all five structural
// paths directly through `admitRegions`, real batches, same construction
// as the flagship gate test above — including the null-origin adoption
// variant (5/5) a second review pass flagged as non-blocking but worth
// locking down given this is authority code.

/// A small STRUCT FOREST, already converged, purpose-built for exercising
/// the move-admission rule directly — no `syntax_claim`/reconcile
/// involved (this is piece 1's own admission mechanism under test, not
/// the syntax overlay): `granted` is the grant root, with two existing
/// structural children `child1`/`child2` already nested under it
/// (enough structure to test a reparent WITHIN the grant); `foreign` is a
/// separate top-level struct node the peer is never granted.
const StructGrantDocs = struct {
    alice: GraphDoc,
    bob: GraphDoc,
    granted: GraphDoc.NodeRef,
    child1: GraphDoc.NodeRef,
    child2: GraphDoc.NodeRef,
    foreign: GraphDoc.NodeRef,
    /// A PLAIN map object — created via ordinary `set`, never
    /// `structCreate`d — for move-admission test 5/5 (null-origin
    /// adoption refusal): its pre-merge `structParent` is `null` because
    /// it was never a struct-forest member at all, not because it's new.
    plain: GraphDoc.NodeRef,

    fn setup(gpa: Allocator) !StructGrantDocs {
        var alice = try GraphDoc.init(gpa, "alice");
        errdefer alice.deinit(gpa);
        const granted_obj = try alice.structCreate(gpa, .root, "b");
        const child1_obj = try alice.structCreate(gpa, .{ .node = granted_obj }, "b");
        const child2_obj = try alice.structCreate(gpa, .{ .node = granted_obj }, "c");
        const foreign_obj = try alice.structCreate(gpa, .root, "a");
        const plain_obj = (try alice.set(gpa, null, "plain", .map)).?;

        const granted_ref = try alice.nodeRef(gpa, granted_obj);
        errdefer granted_ref.free(gpa);
        const child1_ref = try alice.nodeRef(gpa, child1_obj);
        errdefer child1_ref.free(gpa);
        const child2_ref = try alice.nodeRef(gpa, child2_obj);
        errdefer child2_ref.free(gpa);
        const foreign_ref = try alice.nodeRef(gpa, foreign_obj);
        errdefer foreign_ref.free(gpa);
        const plain_ref = try alice.nodeRef(gpa, plain_obj);
        errdefer plain_ref.free(gpa);

        const bytes = try alice.serialize(gpa);
        defer gpa.free(bytes);
        var bob = try GraphDoc.open(gpa, "bob", bytes);
        errdefer bob.deinit(gpa);

        return .{ .alice = alice, .bob = bob, .granted = granted_ref, .child1 = child1_ref, .child2 = child2_ref, .foreign = foreign_ref, .plain = plain_ref };
    }

    fn deinit(self: *StructGrantDocs, gpa: Allocator) void {
        self.granted.free(gpa);
        self.child1.free(gpa);
        self.child2.free(gpa);
        self.foreign.free(gpa);
        self.plain.free(gpa);
        self.alice.deinit(gpa);
        self.bob.deinit(gpa);
    }
};

fn makeStructEnforcer(gpa: Allocator, docs: *StructGrantDocs, sess: *Session, table: *grants.HandleTable) !GraphCollab {
    var gc = try GraphCollab.init(gpa, sess, &docs.alice, "structbuf");
    gc.bindGrants(table);
    return gc;
}

test "W7b move-admission (1/5): ADOPT-IN refused — a peer cannot move a FOREIGN node to become a child of their granted root" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();
    var docs = try StructGrantDocs.setup(gpa);
    defer docs.deinit(gpa);
    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    var gc = try makeStructEnforcer(gpa, &docs, sp.a, &table);
    defer gc.deinit();
    _ = try gc.grantSubtree(docs.granted);

    // The reviewer's exact trace: `structMove(foreign, .{.node = granted},
    // key)` — the node check (post-merge, `foreign` IS now a struct child
    // of `granted`) and a NODE-ONLY destination check would both pass;
    // this must be refused on the ORIGIN check (`foreign`'s pre-merge
    // parent is `.root`, not a member of `{granted}`).
    const bob_foreign = try docs.bob.resolve(docs.foreign);
    const bob_granted = try docs.bob.resolve(docs.granted);
    const key = try GraphDoc.orderKeyBetween(gpa, null, null);
    defer gpa.free(key);
    try docs.bob.structMove(gpa, bob_foreign, .{ .node = bob_granted }, key);

    const av = try docs.alice.version(gpa);
    defer gpa.free(av);
    const batch = try docs.bob.eventsSince(gpa, av);
    defer gpa.free(batch);
    switch (try gc.admitRegions(gpa, batch)) {
        .refuse => |r| {
            defer r.free(gpa);
            try t.expectEqual(GraphCollab.RefusalReason.authority, r.reason);
        },
        .admit => return error.TestUnexpectedResult,
    }
    // Never merged — `foreign` stays exactly where it was, at `.root`.
    const alice_foreign = try docs.alice.resolve(docs.foreign);
    switch (docs.alice.structParent(alice_foreign).?) {
        .root => {},
        .trash, .node => return error.TestUnexpectedResult,
    }
}

test "W7b move-admission (2/5): MOVE-OUT refused — a peer cannot export a granted node to a foreign parent, nor self-delete it via move-to-trash" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();
    var docs = try StructGrantDocs.setup(gpa);
    defer docs.deinit(gpa);
    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    var gc = try makeStructEnforcer(gpa, &docs, sp.a, &table);
    defer gc.deinit();
    _ = try gc.grantSubtree(docs.granted);

    // (2a) `child1` (granted, nested under `granted`) exported OUT to
    // `.root` — origin ∈ union, destination ∉ union.
    {
        const bob_child1 = try docs.bob.resolve(docs.child1);
        const key = try GraphDoc.orderKeyBetween(gpa, null, null);
        defer gpa.free(key);
        try docs.bob.structMove(gpa, bob_child1, .root, key);

        const av = try docs.alice.version(gpa);
        defer gpa.free(av);
        const batch = try docs.bob.eventsSince(gpa, av);
        defer gpa.free(batch);
        switch (try gc.admitRegions(gpa, batch)) {
            .refuse => |r| {
                defer r.free(gpa);
                try t.expectEqual(GraphCollab.RefusalReason.authority, r.reason);
            },
            .admit => return error.TestUnexpectedResult,
        }
    }

    // (2b) the granted root itself moved to `.trash` (self-delete via
    // move) — the corollary named in `structuralChangeAdmitted`'s doc
    // comment, kept from the original rule: a subtree grant confers
    // authority to edit WITHIN a node, not to strike it from existence.
    {
        const bob_granted = try docs.bob.resolve(docs.granted);
        const key = try GraphDoc.orderKeyBetween(gpa, null, null);
        defer gpa.free(key);
        try docs.bob.structMove(gpa, bob_granted, .trash, key);

        const av = try docs.alice.version(gpa);
        defer gpa.free(av);
        const batch = try docs.bob.eventsSince(gpa, av);
        defer gpa.free(batch);
        switch (try gc.admitRegions(gpa, batch)) {
            .refuse => |r| {
                defer r.free(gpa);
                try t.expectEqual(GraphCollab.RefusalReason.authority, r.reason);
            },
            .admit => return error.TestUnexpectedResult,
        }
    }
}

test "W7b move-admission (3/5): REORDER-WITHIN-GRANT admitted — a peer may reparent one already-granted node under another, converges" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();
    var docs = try StructGrantDocs.setup(gpa);
    defer docs.deinit(gpa);
    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    var gc = try makeStructEnforcer(gpa, &docs, sp.a, &table);
    defer gc.deinit();
    _ = try gc.grantSubtree(docs.granted);

    // `child1` reparented under `child2` — a PURE intra-subtree reparent:
    // origin (`child1`'s pre-merge parent, `granted`) ∈ union, destination
    // (`child2`) ∈ union, node (`child1`, post-merge) ∈ union.
    const bob_child1 = try docs.bob.resolve(docs.child1);
    const bob_child2 = try docs.bob.resolve(docs.child2);
    const key = try GraphDoc.orderKeyBetween(gpa, null, null);
    defer gpa.free(key);
    try docs.bob.structMove(gpa, bob_child1, .{ .node = bob_child2 }, key);

    const av = try docs.alice.version(gpa);
    defer gpa.free(av);
    const batch = try docs.bob.eventsSince(gpa, av);
    defer gpa.free(batch);
    switch (try gc.admitRegions(gpa, batch)) {
        .admit => {},
        .refuse => |r| {
            r.free(gpa);
            return error.TestUnexpectedResult;
        },
    }
    const changes = try docs.alice.merge(gpa, batch);
    gpa.free(changes);

    const alice_child1 = try docs.alice.resolve(docs.child1);
    const alice_child2 = try docs.alice.resolve(docs.child2);
    switch (docs.alice.structParent(alice_child1).?) {
        .node => |p| try t.expectEqual(alice_child2, p),
        .root, .trash => return error.TestUnexpectedResult,
    }

    // Convergence.
    {
        const bv = try docs.bob.version(gpa);
        defer gpa.free(bv);
        const sync_batch = try docs.alice.eventsSince(gpa, bv);
        defer gpa.free(sync_batch);
        const sync_changes = try docs.bob.merge(gpa, sync_batch);
        gpa.free(sync_changes);
    }
    {
        const av2 = try docs.alice.version(gpa);
        defer gpa.free(av2);
        const bv2 = try docs.bob.version(gpa);
        defer gpa.free(bv2);
        try t.expectEqual(GraphDoc.VersionOrder.equal, try docs.alice.compareVersions(gpa, av2, bv2));
    }
}

test "W7b move-admission (4/5): struct_CREATE inside the peer's own granted subtree is admitted — the transcript-append analog (a create has no origin to check)" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();
    var docs = try StructGrantDocs.setup(gpa);
    defer docs.deinit(gpa);
    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    var gc = try makeStructEnforcer(gpa, &docs, sp.a, &table);
    defer gc.deinit();
    _ = try gc.grantSubtree(docs.granted);

    const bob_granted = try docs.bob.resolve(docs.granted);
    const key = try GraphDoc.orderKeyBetween(gpa, null, null);
    defer gpa.free(key);
    const new_node = try docs.bob.structCreate(gpa, .{ .node = bob_granted }, key);
    const new_ref = try docs.bob.nodeRef(gpa, new_node);
    defer new_ref.free(gpa);

    const av = try docs.alice.version(gpa);
    defer gpa.free(av);
    const batch = try docs.bob.eventsSince(gpa, av);
    defer gpa.free(batch);
    switch (try gc.admitRegions(gpa, batch)) {
        .admit => {},
        .refuse => |r| {
            r.free(gpa);
            return error.TestUnexpectedResult;
        },
    }
    const changes = try docs.alice.merge(gpa, batch);
    gpa.free(changes);

    const alice_granted = try docs.alice.resolve(docs.granted);
    const alice_new = try docs.alice.resolve(new_ref);
    switch (docs.alice.structParent(alice_new).?) {
        .node => |p| try t.expectEqual(alice_granted, p),
        .root, .trash => return error.TestUnexpectedResult,
    }
}

test "W7b move-admission (5/5): NULL-ORIGIN ADOPTION refused — a peer cannot bare-structMove a PRE-EXISTING plain object (never structCreate'd) into their granted subtree" {
    const gpa = t.allocator;
    var sp: SessionPair = undefined;
    try SessionPair.setup(gpa, &sp);
    defer sp.deinit();
    var docs = try StructGrantDocs.setup(gpa);
    defer docs.deinit(gpa);
    var table = grants.HandleTable.init(gpa);
    defer table.deinit();
    var gc = try makeStructEnforcer(gpa, &docs, sp.a, &table);
    defer gc.deinit();
    _ = try gc.grantSubtree(docs.granted);

    // `plain` PRE-EXISTS (an ordinary `set`-created map object, part of
    // the converged setup) but was NEVER `structCreate`d — its pre-merge
    // `structParent` is `null` because it was never a struct-forest
    // member at all, NOT because it's new. LOCALLY, `ObjectDoc.structMove`
    // has no precondition that `node` was ever `structCreate`d (see
    // `structuralChangeAdmitted`'s doc comment) — bob's own call below
    // succeeds unconditionally, on bob's OWN replica.
    const bob_plain = try docs.bob.resolve(docs.plain);
    const bob_granted = try docs.bob.resolve(docs.granted);
    const key = try GraphDoc.orderKeyBetween(gpa, null, null);
    defer gpa.free(key);
    try docs.bob.structMove(gpa, bob_plain, .{ .node = bob_granted }, key);

    const av = try docs.alice.version(gpa);
    defer gpa.free(av);
    const batch = try docs.bob.eventsSince(gpa, av);
    defer gpa.free(batch);

    // DISCOVERED WHILE WRITING THIS TEST, worth recording precisely: this
    // construction never reaches a `.refuse` VERDICT at all — it is
    // rejected a layer EARLIER and more fundamentally, at stemma's own
    // merge validation. `ObjectDoc`'s `Walker.resolveStructNode`
    // (`objects_state.zig`) requires ANY `struct_move`'s `node` target to
    // trace back to a `.struct_create` op when merging from an UNTRUSTED
    // (remote) source — `plain` fails that (it was `.map_set`, not
    // `.struct_create`) — so `scratch.merge` inside `touchedRegionsWithin`
    // itself returns `error.Corrupt`, propagated straight through
    // `admitRegions` as a thrown error, never a `RegionVerdict`. This is
    // an EVEN STRONGER refusal than `.authority` (the batch is invalid,
    // not merely unauthorized) and makes `structuralChangeAdmitted`'s
    // "pre-existing, no prior struct placement ⇒ ineligible" branch
    // (graph.zig) unreachable via this exact path FOR A REMOTE BATCH —
    // stemma's own decoder already closes it one layer down. That branch
    // is kept anyway, as documented defense-in-depth (a different/future
    // caller of the admission primitive that reaches a node without going
    // through stemma's untrusted-merge validation would still need it),
    // but THIS test's honest job is to confirm the ACTUAL enforcement
    // point: never admitted, never merged, `plain`'s state unchanged —
    // exactly the outcome asked for, via the mechanism that's really
    // there.
    try t.expectError(error.Corrupt, gc.admitRegions(gpa, batch));

    // Never merged — `plain` was never a struct node before, and still
    // isn't: `structParent` stays `null`, not `.node(granted)`. (`self`
    // here is `docs.alice`, whose replica the failed merge never touched —
    // `touchedRegionsWithin`'s scratch clone is thrown away on error,
    // exactly like every other refused/failed admission attempt.)
    const alice_plain = try docs.alice.resolve(docs.plain);
    try t.expect(docs.alice.structParent(alice_plain) == null);
}

test "requests: a lost reply fails the caller at its own deadline, not forever" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };
    // The far end is never serviced: the call goes out, nothing comes back.
    defer lb.link().close();
    const sb = try Session.create(gpa, la.link(), .client, "tok", .own, null);
    defer sb.destroy();

    var rfs = RemoteFs.init(gpa);
    defer rfs.deinit();
    rfs.setTimeout(50 * std.time.ns_per_ms);

    const req = try peer_fs.encodeList(gpa, ".");
    defer gpa.free(req);
    const started = task.nowNs();
    const id = try rfs.request(sb, 0, req);

    var settled: ?requests.Error = null;
    const guard = started + 5 * std.time.ns_per_s;
    while (task.nowNs() < guard) {
        if (rfs.take(id)) |response| {
            try t.expect(response == null); // nobody ever answers
        } else |err| {
            settled = err;
            break;
        }
        testPark(1);
    }
    try t.expectEqual(@as(?requests.Error, error.RequestTimeout), settled);
    // Its own deadline bounds the wait — not the 10s default, not forever.
    const waited = task.nowNs() - started;
    try t.expect(waited >= 50 * std.time.ns_per_ms);
    try t.expect(waited < std.time.ns_per_s);
}

test "requests: a host with nothing to serve refuses out loud instead of going quiet" {
    const gpa = t.allocator;
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

    // No shared root on the host: it has nothing to answer a LIST with.
    var rfs = RemoteFs.init(gpa);
    defer rfs.deinit();
    cc.remote_fs = &rfs;

    var settle: usize = 0;
    while (settle < 80) : (settle += 1) {
        _ = ch.tick(0) catch {};
        _ = cc.tick(0) catch {};
        futexWaitTimed(&sb.out_wake, sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    const req = try peer_fs.encodeList(gpa, ".");
    defer gpa.free(req);
    const id = try rfs.request(sb, cc.base, req);

    var settled: ?requests.Error = null;
    const guard = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < guard) {
        _ = ch.tick(0) catch {};
        _ = cc.tick(0) catch {};
        if (rfs.take(id)) |response| {
            try t.expect(response == null);
        } else |err| {
            settled = err;
            break;
        }
        futexWaitTimed(&sb.out_wake, sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    // The refusal crosses the wire as `fs_err`, well inside the deadline
    // the client would otherwise have had to sit out.
    try t.expectEqual(@as(?requests.Error, error.RequestFailed), settled);
}

test "chaos: a graceful close delivers the queued tail; sever drops it" {
    const gpa = t.allocator;

    // Closing is a FIN once the send buffer drains: the hold lifts, the
    // remaining propagation delay collapses, and the tail lands.
    {
        const fds = try socketPair();
        var sender: FdLink = .{ .fd = fds[0] };
        var receiver: FdLink = .{ .fd = fds[1] };
        defer receiver.link().close();
        var chaos: ChaosLink = .{};
        try chaos.start(gpa, sender.link());
        defer chaos.close();
        chaos.configureLatency(400 * std.time.ns_per_ms, 0, 0);
        chaos.partitioned.store(true, .release);
        try chaos.link().write("tail");

        const started = task.nowNs();
        chaos.close();
        try t.expect(task.nowNs() - started < 300 * std.time.ns_per_ms);

        var got: [4]u8 = undefined;
        var used: usize = 0;
        while (used < got.len) used += try receiver.link().read(got[used..]);
        try t.expectEqualStrings("tail", &got);
    }

    // Severing is the crash the loss tests want: the queue never lands and
    // the peer sees the link end.
    {
        const fds = try socketPair();
        var sender: FdLink = .{ .fd = fds[0] };
        var receiver: FdLink = .{ .fd = fds[1] };
        defer receiver.link().close();
        var chaos: ChaosLink = .{};
        try chaos.start(gpa, sender.link());
        defer chaos.close();
        chaos.configureLatency(400 * std.time.ns_per_ms, 0, 0);
        try chaos.link().write("tail");
        chaos.sever();

        var got: [4]u8 = undefined;
        try t.expectEqual(@as(usize, 0), try receiver.link().read(&got));
    }
}

// ── Publications (architecture §13.2) ────────────────────────────────
//
// A quad is transport; its publication descriptor says which surfaces are
// live. Three tests pin the contract end to end over a real socketpair: a
// peer that never announces a descriptor is ungated (the degradation
// story), a surface outside the export set is dropped, and unpublish
// revokes the exports along with everything translated out of them.

/// The `share` announce EXACTLY as a build predating publications emits it:
/// `uv base | uv name_len | name`, and nothing else on channel 0.
fn postLegacyShare(gpa: Allocator, sess: *Session, base: u64, name: []const u8) !void {
    var announce: std.ArrayList(u8) = .empty;
    defer announce.deinit(gpa);
    try wire.putUv(gpa, &announce, base);
    try wire.putUv(gpa, &announce, name.len);
    try announce.appendSlice(gpa, name);
    try sess.post(.op, @intFromEnum(wire.OpKind.share), 0, announce.items);
}

fn postDiagnostic(gpa: Allocator, sess: *Session, channel: u64, start: u64, end: u64, message: []const u8) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try wire.putUv(gpa, &payload, start);
    try wire.putUv(gpa, &payload, end);
    try wire.putUv(gpa, &payload, 1);
    try wire.putUv(gpa, &payload, message.len);
    try payload.appendSlice(gpa, message);
    try sess.postFeed(channel, 0, payload.items);
}

test "publication: a peer that never announces a descriptor is ungated — presence and diagnostics land exactly as before" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };

    var a_notes = try Document.init(gpa, "alice");
    defer a_notes.deinit(gpa);
    try a_notes.insert(gpa, 0, "notes\n");
    var b_notes = try Document.init(gpa, "bob");
    defer b_notes.deinit(gpa);

    const sa = try Session.create(gpa, la.link(), .server, "tok", .own, null);
    defer sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "tok", .own, null);
    defer sb.destroy();

    // Alice is the OLDER build: a hand-rolled share announce and a bare
    // Collab on the quad. No descriptor is ever sent.
    const base: u64 = 16;
    try postLegacyShare(gpa, sa, base, "notes");
    var acol = try Collab.init(gpa, sa, &a_notes, "alice");
    defer acol.deinit();
    acol.base = base;
    acol.publish_presence = true;

    var cb = try Conn.init(gpa, sb, "bob", .client);
    defer cb.deinit();

    const offer_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < offer_deadline and cb.offers.items.len == 0) {
        _ = try acol.tick(3);
        _ = try cb.tick();
        futexWaitTimed(&sa.out_wake, sa.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expectEqual(@as(usize, 1), cb.offers.items.len);
    try t.expectEqual(base, cb.offers.items[0].base);
    // Nothing to gate with: the quad is the legacy bundle.
    try t.expect(cb.publicationFor(base) == null);

    var layers: layers_mod.Layers = .empty;
    defer layers.deinit(gpa);
    const bcol = try cb.openOffer(0, &b_notes, 2);
    bcol.presence_layer = try layers.claim(gpa, &b_notes, "presence", .replicated, "collab");
    bcol.import_diag_layer = try layers.claim(gpa, &b_notes, "diagnostics", .host, "remote-host");
    try postDiagnostic(gpa, sa, base + 2, 0, 5, "boom");

    const deadline = task.nowNs() + 10 * std.time.ns_per_s;
    var landed = false;
    while (!landed and task.nowNs() < deadline) {
        _ = try acol.tick(3);
        _ = try cb.tick();
        landed = bcol.presence_layer.?.spanCount() > 0 and bcol.import_diag_layer.?.spanCount() > 0;
        if (!landed) futexWaitTimed(&sa.out_wake, sa.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(landed);
    try t.expectEqualStrings("alice", bcol.presence_layer.?.resolvedSpan(0).message);
    try t.expectEqual(@as(usize, 3), bcol.presence_layer.?.resolvedSpan(0).start);
    try t.expectEqualStrings("boom", bcol.import_diag_layer.?.resolvedSpan(0).message);
}

test "publication: a surface the descriptor does not export is dropped, while the replica keeps converging" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };

    var a_notes = try Document.init(gpa, "alice");
    defer a_notes.deinit(gpa);
    try a_notes.insert(gpa, 0, "notes\n");
    var b_notes = try Document.init(gpa, "bob");
    defer b_notes.deinit(gpa);

    const sa = try Session.create(gpa, la.link(), .server, "tok", .own, null);
    defer sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "tok", .own, null);
    defer sb.destroy();
    var ca = try Conn.init(gpa, sa, "alice", .server);
    defer ca.deinit();
    var cb = try Conn.init(gpa, sb, "bob", .client);
    defer cb.deinit();

    // Shared WITHOUT the presence surface: alice's cursor has nowhere to
    // ride, even though her driver still publishes it.
    const acol = try ca.shareExports(&a_notes, "notes", 1, .{ .presence = false });
    acol.publish_presence = true;
    acol.cursor_offset = 3;
    acol.selection_anchor = 3;

    const offer_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < offer_deadline and (cb.offers.items.len == 0 or cb.publicationFor(acol.base) == null)) {
        _ = try ca.tick();
        _ = try cb.tick();
        futexWaitTimed(&sa.out_wake, sa.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    const descriptor = cb.publicationFor(acol.base) orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("notes", descriptor.resource);
    try t.expect(descriptor.replicaExport() != null);
    try t.expect(descriptor.surfaceOps(.presence) == null);
    try t.expect(descriptor.surfaceOps(.diagnostics) != null);

    var layers: layers_mod.Layers = .empty;
    defer layers.deinit(gpa);
    const bcol = try cb.openOffer(0, &b_notes, 2);
    bcol.presence_layer = try layers.claim(gpa, &b_notes, "presence", .replicated, "collab");

    const deadline = task.nowNs() + 10 * std.time.ns_per_s;
    var converged = false;
    while (!converged and task.nowNs() < deadline) {
        _ = try ca.tick();
        _ = try cb.tick();
        const text = try b_notes.text().toOwnedSlice(gpa);
        defer gpa.free(text);
        converged = std.mem.eql(u8, text, "notes\n");
        if (!converged) futexWaitTimed(&sa.out_wake, sa.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(converged);
    // The replica is live; the unexported surface never renders a cursor.
    for (0..64) |_| {
        _ = try ca.tick();
        _ = try cb.tick();
    }
    try t.expectEqual(@as(usize, 0), bcol.presence_layer.?.spanCount());
    try t.expectEqual(@as(usize, 0), bcol.presence.items.len);
}

test "publication: unpublish advances the epoch, marks the quad stale, and invalidates translated references" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };

    var a_notes = try Document.init(gpa, "alice");
    defer a_notes.deinit(gpa);
    try a_notes.insert(gpa, 0, "notes\n");
    var b_notes = try Document.init(gpa, "bob");
    defer b_notes.deinit(gpa);

    const sa = try Session.create(gpa, la.link(), .server, "tok", .own, null);
    defer sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "tok", .own, null);
    defer sb.destroy();
    var ca = try Conn.init(gpa, sa, "alice", .server);
    defer ca.deinit();
    var cb = try Conn.init(gpa, sb, "bob", .client);
    defer cb.deinit();

    const acol = try ca.shareExports(&a_notes, "notes", 1, .legacy);
    const base = acol.base;
    acol.publish_presence = true;
    acol.cursor_offset = 3;
    acol.selection_anchor = 3;

    const offer_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < offer_deadline and cb.offers.items.len == 0) {
        _ = try ca.tick();
        _ = try cb.tick();
        futexWaitTimed(&sa.out_wake, sa.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expectEqual(@as(usize, 1), cb.offers.items.len);

    var layers: layers_mod.Layers = .empty;
    defer layers.deinit(gpa);
    const bcol = try cb.openOffer(0, &b_notes, 2);
    bcol.presence_layer = try layers.claim(gpa, &b_notes, "presence", .replicated, "collab");
    bcol.import_diag_layer = try layers.claim(gpa, &b_notes, "diagnostics", .host, "remote-host");
    try postDiagnostic(gpa, sa, base + 2, 0, 5, "boom");

    const landed_deadline = task.nowNs() + 10 * std.time.ns_per_s;
    var landed = false;
    while (!landed and task.nowNs() < landed_deadline) {
        _ = try ca.tick();
        _ = try cb.tick();
        landed = bcol.presence_layer.?.spanCount() > 0 and bcol.import_diag_layer.?.spanCount() > 0;
        if (!landed) futexWaitTimed(&sa.out_wake, sa.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(landed);
    try t.expectEqual(@as(u32, 0), cb.publicationFor(base).?.epoch);

    // Closing the shared buffer unpublishes the quad.
    ca.unbindTag(1);
    const stale_deadline = task.nowNs() + 10 * std.time.ns_per_s;
    var stale = false;
    while (!stale and task.nowNs() < stale_deadline) {
        _ = try cb.tick();
        stale = cb.publicationFor(base).?.stale;
        if (!stale) futexWaitTimed(&sb.out_wake, sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }
    try t.expect(stale);
    try t.expectEqual(@as(u32, 1), cb.publicationFor(base).?.epoch);
    try t.expect(cb.offers.items[0].stale);
    // Everything translated out of the publication is gone; the replica
    // survives as an ordinary local document.
    try t.expectEqual(@as(usize, 0), bcol.presence_layer.?.spanCount());
    try t.expectEqual(@as(usize, 0), bcol.import_diag_layer.?.spanCount());
    const text = try b_notes.text().toOwnedSlice(gpa);
    defer gpa.free(text);
    try t.expectEqualStrings("notes\n", text);
}

// ── Per-export grants over the wire (§13.5) ─────────────────────────
//
// One host, one client, one real encrypted link, one publication. The
// grade is set to `.own` on the host side in most of these precisely to
// prove it is only a CEILING: everything the peer may actually do comes
// from the export grants, and a grade that permits everything grants
// nothing on its own once a publication is confined.

const ExportRig = struct {
    la: FdLink,
    lb: FdLink,
    host: *Session,
    peer: *Session,
    doc_host: Document,
    doc_peer: Document,
    ch: Collab,
    cp: Collab,
    book: grants.ExportBook,

    /// Out-pointer, same reasoning as `SessionPair.setup`'s doc comment —
    /// and doubly so here: `Collab` stores `*Document` pointers INTO this
    /// struct, which a by-value return would strand.
    fn setup(gpa: Allocator, self: *ExportRig, host_access: session.Access) !void {
        const fds = try socketPair();
        self.la = .{ .fd = fds[0] };
        self.lb = .{ .fd = fds[1] };
        self.host = try Session.create(gpa, self.la.link(), .server, "tok", host_access, null);
        errdefer self.host.destroy();
        self.peer = try Session.create(gpa, self.lb.link(), .client, "tok", .own, null);
        errdefer self.peer.destroy();
        const deadline = task.nowNs() + 5 * std.time.ns_per_s;
        while (!(self.host.established.load(.acquire) and self.peer.established.load(.acquire))) {
            if (task.nowNs() > deadline) return error.NotEstablished;
            testPark(2);
        }
        self.doc_host = try Document.init(gpa, "host");
        errdefer self.doc_host.deinit(gpa);
        self.doc_peer = try Document.init(gpa, "peer");
        errdefer self.doc_peer.deinit(gpa);
        self.book = grants.ExportBook.init(gpa);
        self.ch = try Collab.init(gpa, self.host, &self.doc_host, "host");
        errdefer self.ch.deinit();
        self.cp = try Collab.init(gpa, self.peer, &self.doc_peer, "peer");
        // The client-role fail-safe `Conn.bind` applies at a real join:
        // hold off local edits until the host's announcement arrives.
        self.doc_peer.my_grant = .view;
        self.cp.client_bound = true;
    }

    fn deinit(self: *ExportRig, gpa: Allocator) void {
        self.cp.deinit();
        self.ch.deinit();
        self.book.deinit();
        self.doc_peer.deinit(gpa);
        self.doc_host.deinit(gpa);
        self.peer.destroy();
        self.host.destroy();
    }

    fn pump(self: *ExportRig, rounds: usize) !void {
        for (0..rounds) |_| {
            _ = try self.ch.tick(0);
            _ = try self.cp.tick(0);
            napUs(300);
        }
    }

    /// Pump until the grantee's ANNOUNCED op-set is exactly `want`.
    fn untilOps(self: *ExportRig, want: grants.OpSet) !bool {
        for (0..4000) |_| {
            _ = try self.ch.tick(0);
            _ = try self.cp.tick(0);
            if (self.cp.announced.ops().bits == want.bits) return true;
            napUs(300);
        }
        return false;
    }

    fn untilText(self: *ExportRig, gpa: Allocator, doc: *Document, needle: []const u8) !bool {
        for (0..4000) |_| {
            _ = try self.ch.tick(0);
            _ = try self.cp.tick(0);
            const txt = try doc.text().toOwnedSlice(gpa);
            defer gpa.free(txt);
            if (std.mem.indexOf(u8, txt, needle) != null) return true;
            napUs(300);
        }
        return false;
    }

    fn hostText(self: *ExportRig, gpa: Allocator) ![]u8 {
        return self.doc_host.text().toOwnedSlice(gpa);
    }
};

const read_export = grants.OpSet.of(&.{ .replica_read, .presence_read, .presence_publish });
const write_export = read_export.with(.replica_write);

test "export grants: a read-only export refuses at the grantee's own preflight FIRST — the out-of-grant op is never minted, so the frontier never carries it" {
    const gpa = t.allocator;
    var rig: ExportRig = undefined;
    try ExportRig.setup(gpa, &rig, .own); // a grade that permits everything...
    defer rig.deinit(gpa);

    try rig.doc_host.insert(gpa, 0, "base\n");
    try rig.ch.publish(&rig.book, 1);
    // ...grants nothing on its own: this is the whole authority the peer has.
    _ = try rig.ch.grantExport(read_export, .whole, .until_revoked);

    try t.expect(try rig.untilOps(read_export));
    // The announcement lands in the ONE existing text edit gate, so the
    // preflight is structural rather than a second thing to remember.
    try t.expectEqual(session.Access.view, rig.doc_peer.my_grant);
    try t.expectEqual(grants.Reason.out_of_ops, rig.cp.mayMintOp());
    // Reading is exactly what was granted, and it works.
    try t.expect(try rig.untilText(gpa, &rig.doc_peer, "base"));

    // The edit path (simulated here exactly as a real one would consult it)
    // asks BEFORE committing. The refusal is local and visible; nothing is
    // minted, so this replica's own frontier does not move.
    const before = try rig.doc_peer.version(gpa);
    defer gpa.free(before);
    if (rig.cp.mayMintOp() == .ok) try rig.doc_peer.insert(gpa, rig.doc_peer.text().byteLen(), "PEER");
    const after = try rig.doc_peer.version(gpa);
    defer gpa.free(after);
    try t.expectEqualSlices(u8, before, after);

    // No poison: nothing the peer authored ever reached the shared replica,
    // because nothing was ever authored. (The host still records refusals
    // here — a read-only peer re-offers its frontier after every merge, and
    // that echo is refused by the same authority check; the point is that no
    // OP of the peer's own is in any of them.)
    try rig.pump(200);
    const th = try rig.hostText(gpa);
    defer gpa.free(th);
    try t.expect(std.mem.indexOf(u8, th, "PEER") == null);

    // Adding the write export opens the SAME preflight — a second grant
    // widens the union, it does not re-grade the connection.
    _ = try rig.ch.grantExport(grants.OpSet.of(&.{.replica_write}), .whole, .until_revoked);
    try t.expect(try rig.untilOps(write_export));
    try t.expectEqual(grants.Reason.ok, rig.cp.mayMintOp());
    try t.expectEqual(session.Access.edit, rig.doc_peer.my_grant);
    try rig.doc_peer.insert(gpa, rig.doc_peer.text().byteLen(), "PEER");
    try t.expect(try rig.untilText(gpa, &rig.doc_host, "PEER"));
}

test "export grants: revocation announces, the grantee's preflight closes at once, and an already-flowing stream is re-checked at the admission point" {
    const gpa = t.allocator;
    var rig: ExportRig = undefined;
    try ExportRig.setup(gpa, &rig, .own);
    defer rig.deinit(gpa);

    try rig.doc_host.insert(gpa, 0, "base\n");
    try rig.ch.publish(&rig.book, 1);
    _ = try rig.ch.grantExport(write_export, .whole, .until_revoked);
    try t.expect(try rig.untilOps(write_export));

    // A live, admitted stream.
    try rig.doc_peer.insert(gpa, rig.doc_peer.text().byteLen(), "ONE");
    try t.expect(try rig.untilText(gpa, &rig.doc_host, "ONE"));

    // `setPeerAccess`'s per-export sibling.
    try t.expectEqual(@as(usize, 1), rig.ch.revokeExports());
    try t.expect(try rig.untilOps(.empty));
    try t.expectEqual(grants.Reason.never_granted, rig.cp.mayMintOp());
    try t.expectEqual(session.Access.view, rig.doc_peer.my_grant);

    // A grantee that IGNORES its preflight (buggy, older, or malicious)
    // still cannot get an op in: admission re-decides on every frame, which
    // is the honest in-flight granularity a batched protocol has.
    rig.ch.last_refusal = null;
    try rig.doc_peer.insert(gpa, rig.doc_peer.text().byteLen(), "TWO");
    try rig.pump(400);
    const th = try rig.hostText(gpa);
    defer gpa.free(th);
    try t.expect(std.mem.indexOf(u8, th, "ONE") != null); // the admitted edit stands
    try t.expect(std.mem.indexOf(u8, th, "TWO") == null);
    try t.expectEqual(grants.Reason.never_granted, rig.ch.last_refusal.?);
}

test "export grants: unpublishing kills the epoch — admission refuses with dead_epoch, distinct from never having been granted" {
    const gpa = t.allocator;
    var rig: ExportRig = undefined;
    try ExportRig.setup(gpa, &rig, .own);
    defer rig.deinit(gpa);

    try rig.doc_host.insert(gpa, 0, "base\n");
    try rig.ch.publish(&rig.book, 1);
    _ = try rig.ch.grantExport(write_export, .whole, .until_revoked);
    try t.expect(try rig.untilOps(write_export));
    try rig.doc_peer.insert(gpa, rig.doc_peer.text().byteLen(), "ONE");
    try t.expect(try rig.untilText(gpa, &rig.doc_host, "ONE"));

    // §13.2: unpublishing advances the epoch and invalidates every export
    // minted against it — no row walk, no window.
    try rig.ch.unpublish();
    try t.expect(try rig.untilOps(.empty));
    // A reference the grantee still holds at the old epoch says so.
    try t.expectEqual(
        grants.Reason.dead_epoch,
        rig.cp.announced.mayAt(.{ .id = 1, .epoch = 1 }, .replica_write),
    );

    rig.ch.last_refusal = null;
    try rig.doc_peer.insert(gpa, rig.doc_peer.text().byteLen(), "GHOST");
    try rig.pump(400);
    const th = try rig.hostText(gpa);
    defer gpa.free(th);
    try t.expect(std.mem.indexOf(u8, th, "GHOST") == null);
    // The distinct reason is the point: "your grant outlived its
    // publication" is not "you were never granted anything".
    try t.expectEqual(grants.Reason.dead_epoch, rig.ch.last_refusal.?);
}

test "export grants: a legacy grade-only peer is unchanged — one byte in, the preset bundle out, the same ops admitted and dropped" {
    const gpa = t.allocator;
    var rig: ExportRig = undefined;
    // No publish, no book: the wire and the behavior are exactly pre-slice.
    try ExportRig.setup(gpa, &rig, .edit);
    defer rig.deinit(gpa);

    try rig.doc_host.insert(gpa, 0, "base\n");
    try t.expect(try rig.untilOps(session.Access.edit.ops()));
    try t.expect(!rig.cp.announced.described); // a grade byte, nothing more
    try t.expectEqual(session.Access.edit, rig.doc_peer.my_grant);
    try t.expectEqual(grants.Reason.ok, rig.cp.mayMintOp());

    try rig.doc_peer.insert(gpa, rig.doc_peer.text().byteLen(), "ONE");
    try t.expect(try rig.untilText(gpa, &rig.doc_host, "ONE"));

    // A live downgrade (`setPeerAccess`) still re-announces and still gates.
    rig.host.access = .view;
    try t.expect(try rig.untilOps(session.Access.view.ops()));
    try t.expectEqual(session.Access.view, rig.doc_peer.my_grant);
    try t.expectEqual(grants.Reason.out_of_ops, rig.cp.mayMintOp());

    rig.ch.last_refusal = null;
    try rig.doc_peer.insert(gpa, rig.doc_peer.text().byteLen(), "TWO");
    try rig.pump(400);
    const th = try rig.hostText(gpa);
    defer gpa.free(th);
    try t.expect(std.mem.indexOf(u8, th, "ONE") != null);
    try t.expect(std.mem.indexOf(u8, th, "TWO") == null);
    try t.expectEqual(grants.Reason.out_of_ops, rig.ch.last_refusal.?);
}

test "export grants: surfaces are granted and enforced SEPARATELY — replica access without presence drops the peer's cursor, adding presence lights it up" {
    const gpa = t.allocator;
    var rig: ExportRig = undefined;
    try ExportRig.setup(gpa, &rig, .own);
    defer rig.deinit(gpa);

    try rig.doc_host.insert(gpa, 0, "0123456789");
    try rig.ch.publish(&rig.book, 1);
    // Read the document, but do NOT show me where you are.
    const replica_only = grants.OpSet.of(&.{ .replica_read, .replica_write });
    _ = try rig.ch.grantExport(replica_only, .whole, .until_revoked);
    try t.expect(try rig.untilOps(replica_only));

    try rig.cp.setPublishPresence(true);
    try t.expect(try rig.untilText(gpa, &rig.doc_peer, "0123456789"));
    try rig.pump(300);
    try t.expect(rig.ch.presenceNamed("peer") == null); // dropped at admission

    // The same peer, the same channel, one more export. Presence is
    // latest-wins soft state, so it re-publishes on the grantee's next caret
    // move — nothing replays what the host already dropped.
    _ = try rig.ch.grantExport(grants.OpSet.of(&.{.presence_publish}), .whole, .until_revoked);
    try t.expect(try rig.untilOps(replica_only.with(.presence_publish)));
    var seen = false;
    for (0..4000) |_| {
        _ = try rig.ch.tick(0);
        _ = try rig.cp.tick(3);
        if (rig.ch.presenceNamed("peer") != null) {
            seen = true;
            break;
        }
        napUs(300);
    }
    try t.expect(seen);
}

test "export grants: the connection grade is a CEILING over the wire — an export the grade forbids never admits, and is never announced as held" {
    const gpa = t.allocator;
    var rig: ExportRig = undefined;
    try ExportRig.setup(gpa, &rig, .view); // the maximum this link may reach
    defer rig.deinit(gpa);

    try rig.doc_host.insert(gpa, 0, "base\n");
    try rig.ch.publish(&rig.book, 1);
    // The owner mints write anyway — the intersection, not the mint, decides.
    _ = try rig.ch.grantExport(write_export, .whole, .until_revoked);

    try t.expect(try rig.untilOps(write_export.intersect(session.Access.view.ops())));
    try t.expectEqual(session.Access.view, rig.doc_peer.my_grant);
    try t.expectEqual(grants.Reason.out_of_ops, rig.cp.mayMintOp());

    rig.ch.last_refusal = null;
    try rig.doc_peer.insert(gpa, rig.doc_peer.text().byteLen(), "PEER");
    try rig.pump(400);
    const th = try rig.hostText(gpa);
    defer gpa.free(th);
    try t.expect(std.mem.indexOf(u8, th, "PEER") == null);
    try t.expectEqual(grants.Reason.out_of_ops, rig.ch.last_refusal.?);
}

/// Two `Collab`s over a socket pair, the host serving `root` under `grant`.
/// The shape every export-surface test below drives its requests through.
const FsPair = struct {
    fds: [2]i32,
    la: FdLink,
    lb: FdLink,
    host: Document,
    client: Document,
    sa: *Session,
    sb: *Session,
    ch: Collab,
    cc: Collab,
    rfs: RemoteFs,

    fn init(gpa: std.mem.Allocator, self: *FsPair, root: *rooted_fs.RootedFs, grant: peer_fs.Grant) !void {
        self.fds = try socketPair();
        self.la = .{ .fd = self.fds[0] };
        self.lb = .{ .fd = self.fds[1] };
        self.host = try Document.init(gpa, "host");
        self.client = try Document.init(gpa, "client");
        self.sa = try Session.create(gpa, self.la.link(), .server, "tok", .own, null);
        self.sb = try Session.create(gpa, self.lb.link(), .client, "tok", .own, null);
        self.ch = try Collab.init(gpa, self.sa, &self.host, "host");
        self.cc = try Collab.init(gpa, self.sb, &self.client, "client");
        self.rfs = RemoteFs.init(gpa);
        self.ch.peer_fs_root = root;
        self.ch.fs_grant = grant;
        self.cc.remote_fs = &self.rfs;
        var settle: usize = 0;
        while (settle < 80) : (settle += 1) self.turn();
    }

    fn deinit(self: *FsPair, gpa: std.mem.Allocator) void {
        self.rfs.deinit();
        self.cc.deinit();
        self.ch.deinit();
        self.sb.destroy();
        self.sa.destroy();
        self.client.deinit(gpa);
        self.host.deinit(gpa);
    }

    fn turn(self: *FsPair) void {
        _ = self.ch.tick(0) catch {};
        _ = self.cc.tick(0) catch {};
        futexWaitTimed(&self.sb.out_wake, self.sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }

    /// Post `req` and drive both ends until it settles — a response, the
    /// host's refusal, or (never, here) its own deadline.
    fn call(self: *FsPair, req: []const u8) requests.Error!?[]u8 {
        const id = self.rfs.request(self.sb, self.cc.base, req) catch return null;
        const guard = task.nowNs() + 5 * std.time.ns_per_s;
        while (task.nowNs() < guard) {
            if (try self.rfs.take(id)) |response| return response;
            self.turn();
        }
        return null;
    }
};

test "peer_fs exports: a hierarchy-only peer lists, and is refused the bytes by name" {
    const gpa = t.allocator;
    var pbuf: [128]u8 = undefined;
    const root_path = try std.fmt.bufPrintZ(&pbuf, "/tmp/weft-peerexports-{d}", .{linux.getpid()});
    _ = linux.rmdir(root_path.ptr);
    if (linux.errno(linux.mkdir(root_path.ptr, 0o755)) != .SUCCESS) return error.Mkdir;
    var root = try rooted_fs.RootedFs.open(root_path.ptr);
    defer root.close();
    defer {
        _ = linux.unlinkat(root.root_fd, "secret.txt", 0);
        _ = linux.rmdir(root_path.ptr);
    }
    try root.write("secret.txt", "contents");

    var pair: FsPair = undefined;
    try FsPair.init(gpa, &pair, &root, .{ .hierarchy = true });
    defer pair.deinit(gpa);

    // The one granted surface answers.
    const list_req = try peer_fs.encodeList(gpa, ".");
    defer gpa.free(list_req);
    const listing = (try pair.call(list_req)).?;
    defer gpa.free(listing);
    const decoded = peer_fs.decodeResponse(listing).?;
    try t.expectEqual(peer_fs.Status.ok, decoded.status);
    try t.expect(std.mem.indexOf(u8, decoded.payload, "secret.txt") != null);

    // The other two refuse out loud, as "not granted" rather than a deadline
    // the requester sits out — and never as file contents.
    const read_req = try peer_fs.encodeRead(gpa, "secret.txt");
    defer gpa.free(read_req);
    try t.expectError(error.RequestDenied, pair.call(read_req));
    const write_req = try peer_fs.encodeWrite(gpa, "secret.txt", peer_fs.tokenOf("contents"), "overwritten");
    defer gpa.free(write_req);
    try t.expectError(error.RequestDenied, pair.call(write_req));

    // Refused at the surface, not at the file: the bytes never changed.
    const still = try root.read(gpa, "secret.txt");
    defer gpa.free(still);
    try t.expectEqualStrings("contents", still);
}

test "peer_fs exports: mutate is granted on its own, not as the top of a ladder" {
    const gpa = t.allocator;
    var pbuf: [128]u8 = undefined;
    const root_path = try std.fmt.bufPrintZ(&pbuf, "/tmp/weft-peermutate-{d}", .{linux.getpid()});
    _ = linux.rmdir(root_path.ptr);
    if (linux.errno(linux.mkdir(root_path.ptr, 0o755)) != .SUCCESS) return error.Mkdir;
    var root = try rooted_fs.RootedFs.open(root_path.ptr);
    defer root.close();
    defer {
        _ = linux.unlinkat(root.root_fd, "note.txt", 0);
        _ = linux.rmdir(root_path.ptr);
    }

    var pair: FsPair = undefined;
    try FsPair.init(gpa, &pair, &root, .{ .mutate = true });
    defer pair.deinit(gpa);

    // A fresh create against the zero token: writing needs no read grant.
    const write_req = try peer_fs.encodeWrite(gpa, "note.txt", peer_fs.tokenOf(""), "written");
    defer gpa.free(write_req);
    const written = (try pair.call(write_req)).?;
    defer gpa.free(written);
    try t.expectEqual(peer_fs.Status.ok, peer_fs.decodeResponse(written).?.status);
    const got = try root.read(gpa, "note.txt");
    defer gpa.free(got);
    try t.expectEqualStrings("written", got);

    // Listing the tree it may write to is a surface it was not granted.
    const list_req = try peer_fs.encodeList(gpa, ".");
    defer gpa.free(list_req);
    try t.expectError(error.RequestDenied, pair.call(list_req));
}

test "peer_fs exports: the legacy read preset still lists and reads" {
    const gpa = t.allocator;
    var pbuf: [128]u8 = undefined;
    const root_path = try std.fmt.bufPrintZ(&pbuf, "/tmp/weft-peerlegacy-{d}", .{linux.getpid()});
    _ = linux.rmdir(root_path.ptr);
    if (linux.errno(linux.mkdir(root_path.ptr, 0o755)) != .SUCCESS) return error.Mkdir;
    var root = try rooted_fs.RootedFs.open(root_path.ptr);
    defer root.close();
    defer {
        _ = linux.unlinkat(root.root_fd, "hello.txt", 0);
        _ = linux.rmdir(root_path.ptr);
    }
    try root.write("hello.txt", "shared bytes");

    var pair: FsPair = undefined;
    try FsPair.init(gpa, &pair, &root, .read);
    defer pair.deinit(gpa);

    const list_req = try peer_fs.encodeList(gpa, ".");
    defer gpa.free(list_req);
    const listing = (try pair.call(list_req)).?;
    defer gpa.free(listing);
    try t.expectEqual(peer_fs.Status.ok, peer_fs.decodeResponse(listing).?.status);

    const read_req = try peer_fs.encodeRead(gpa, "hello.txt");
    defer gpa.free(read_req);
    const bytes = (try pair.call(read_req)).?;
    defer gpa.free(bytes);
    try t.expectEqualStrings("shared bytes", peer_fs.decodeResponse(bytes).?.payload);

    // The preset stops where it always did: it carries no mutate surface.
    const write_req = try peer_fs.encodeWrite(gpa, "hello.txt", peer_fs.tokenOf("shared bytes"), "clobbered");
    defer gpa.free(write_req);
    try t.expectError(error.RequestDenied, pair.call(write_req));
}

// ── §18 collaboration acceptance gates ──────────────────────────────
// The offline, skew, and asymmetry gates of
// doc/contextual-workspace-architecture.md §13.7 and §18, each driven
// through the real wire rather than against a driver's internals.

/// Counts what a session PUTS on the wire, per quad channel — the
/// instrument gate C needs (see `Session.Tap`). `post` runs only on the
/// caller's thread, so plain fields are enough: heartbeats are sealed
/// straight from the writer and never pass here.
const QuadEmissions = struct {
    base: u64 = 0,
    ops: usize = 0,
    presence: usize = 0,
    diagnostics: usize = 0,
    blobs: usize = 0,

    fn tap(self: *QuadEmissions) Session.Tap {
        return .{ .ctx = self, .postedFn = saw };
    }

    fn saw(ctx: ?*anyopaque, class: wire.Class, kind: u8, channel: u64) void {
        _ = kind;
        const self: *QuadEmissions = @ptrCast(@alignCast(ctx.?));
        if (class == .control) return;
        if (channel == self.base) self.ops += 1;
        if (channel == self.base + 1) self.presence += 1;
        if (channel == self.base + 2) self.diagnostics += 1;
        if (channel == self.base + 3) self.blobs += 1;
    }
};

/// A `.share` announce built by hand, so a gate can feed the decoder a
/// descriptor this build was never taught to emit.
fn craftAnnounce(gpa: Allocator, base: u64, name: []const u8, trailer: []const u8) ![]u8 {
    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(gpa);
    try wire.putUv(gpa, &payload, base);
    try wire.putUv(gpa, &payload, name.len);
    try payload.appendSlice(gpa, name);
    try payload.appendSlice(gpa, trailer);
    return payload.toOwnedSlice(gpa);
}

/// Both documents hold the same number of bytes. A file-scoped pair rather
/// than a closure: the pump helper takes a plain function.
var converge_a: *Document = undefined;
var converge_b: *Document = undefined;

fn convergedByLen() bool {
    return converge_b.text().byteLen() == converge_a.text().byteLen();
}

/// Drive both ends until `done`, or give up. Returns whether it held.
fn pumpCollabsUntil(a: *Collab, b: *Collab, cursor: usize, done: *const fn () bool) !bool {
    const deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < deadline) {
        _ = a.tick(cursor) catch {};
        _ = b.tick(0) catch {};
        if (done()) return true;
        testPark(1);
    }
    return done();
}

/// One `peer_fs` call, pumped to its reply. Returns the owned response.
fn callPeerFs(h: *Collab, c: *Collab, fs: *RemoteFs, s: *Session, req: []const u8) ![]u8 {
    const id = try fs.request(s, c.base, req);
    const deadline = task.nowNs() + 10 * std.time.ns_per_s;
    while (task.nowNs() < deadline) {
        _ = h.tick(0) catch {};
        _ = c.tick(0) catch {};
        if (try fs.take(id)) |resp| return resp;
        testPark(1);
    }
    return error.NoReply;
}

test "gate A (§13.7): an offline peer's mutation refuses at once, and reconnecting never replays it" {
    const gpa = t.allocator;

    var pbuf: [128]u8 = undefined;
    const root_path = try std.fmt.bufPrintZ(&pbuf, "/tmp/weft-gate-a-{d}", .{linux.getpid()});
    _ = linux.rmdir(root_path.ptr);
    if (linux.errno(linux.mkdir(root_path.ptr, 0o755)) != .SUCCESS) return error.Mkdir;
    var root = try rooted_fs.RootedFs.open(root_path.ptr);
    defer root.close();
    defer {
        _ = linux.unlinkat(root.root_fd, "note.txt", 0);
        _ = linux.rmdir(root_path.ptr);
    }
    try root.write("note.txt", "one");

    var host = try Document.init(gpa, "host");
    defer host.deinit(gpa);
    var client = try Document.init(gpa, "client");
    defer client.deinit(gpa);
    var rfs = RemoteFs.init(gpa);
    defer rfs.deinit();

    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };
    const sa = try Session.create(gpa, la.link(), .server, "tok", .own, null);
    var sa_live = true;
    defer if (sa_live) sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "tok", .own, null);
    var sb_live = true;
    defer if (sb_live) sb.destroy();

    var ch = try Collab.init(gpa, sa, &host, "host");
    defer ch.deinit();
    var cc = try Collab.init(gpa, sb, &client, "client");
    defer cc.deinit();
    ch.peer_fs_root = &root;
    ch.fs_grant = .read_write;
    cc.remote_fs = &rfs;

    // A call the peer answers, so the refusal below is about being offline
    // and nothing else: read the file's token, then write through it.
    const stat_req = try peer_fs.encodeStat(gpa, "note.txt");
    defer gpa.free(stat_req);
    const stat_resp = try callPeerFs(&ch, &cc, &rfs, sb, stat_req);
    defer gpa.free(stat_resp);
    const token_bytes = peer_fs.decodeResponse(stat_resp).?.payload;
    var token: peer_fs.Token = undefined;
    @memcpy(&token, token_bytes);

    const write_req = try peer_fs.encodeWrite(gpa, "note.txt", token, "two");
    defer gpa.free(write_req);
    const write_resp = try callPeerFs(&ch, &cc, &rfs, sb, write_req);
    defer gpa.free(write_resp);
    try t.expectEqual(peer_fs.Status.ok, peer_fs.decodeResponse(write_resp).?.status);
    {
        const on_disk = try root.read(gpa, "note.txt");
        defer gpa.free(on_disk);
        try t.expectEqualStrings("two", on_disk);
    }

    // The cable goes out.
    sa.destroy();
    sa_live = false;
    const offline_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < offline_deadline and sb.liveness() != .offline) {
        _ = cc.tick(0) catch {};
        testPark(1);
    }
    try t.expectEqual(Session.Liveness.offline, sb.liveness());

    // The mutation refuses HERE, with a reason, rather than queueing for a
    // reconnect that would replay it against an owner who never saw it.
    const offline_write = try peer_fs.encodeWrite(gpa, "note.txt", peer_fs.tokenOf("two"), "three");
    defer gpa.free(offline_write);
    try t.expectError(error.PeerOffline, rfs.request(sb, cc.base, offline_write));

    // Reconnect. Nothing was held to replay: the file still reads what the
    // last ADMITTED write left, and the replica resyncs from its frontier.
    sb.destroy();
    sb_live = false;
    const fds2 = try socketPair();
    var la2: FdLink = .{ .fd = fds2[0] };
    var lb2: FdLink = .{ .fd = fds2[1] };
    const sa2 = try Session.create(gpa, la2.link(), .server, "tok", .own, null);
    defer sa2.destroy();
    const sb2 = try Session.create(gpa, lb2.link(), .client, "tok", .own, null);
    defer sb2.destroy();
    ch.rebind(sa2);
    cc.rebind(sb2);

    try host.insert(gpa, 0, "resynced\n");
    converge_a = &host;
    converge_b = &client;
    try t.expect(try pumpCollabsUntil(&ch, &cc, 0, convergedByLen));

    const after = try root.read(gpa, "note.txt");
    defer gpa.free(after);
    try t.expectEqualStrings("two", after);
}

test "gate B (§13.4): an unknown op kind and an undecodable export surface are both skipped, peer intact" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };
    const sa = try Session.create(gpa, la.link(), .server, "tok", .own, null);
    defer sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "tok", .own, null);
    defer sb.destroy();
    var ca = try Conn.init(gpa, sa, "alice", .server);
    defer ca.deinit();
    var cb = try Conn.init(gpa, sb, "bob", .client);
    defer cb.deinit();

    var doc_a = try Document.init(gpa, "alice");
    defer doc_a.deinit(gpa);
    try doc_a.insert(gpa, 0, "hello\n");
    const shared = try ca.share(&doc_a, "shared", 1);

    // A frame kind from a build this one predates, on the live quad; a
    // descriptor whose export surface this build cannot decode; and a
    // KNOWN surface carrying trailing fields this build ignores.
    try sa.post(.op, 250, shared.base, "from the future");
    const undecodable = try craftAnnounce(gpa, 64, "future-doc", &.{ 99, 7, 7 });
    defer gpa.free(undecodable);
    try sa.post(.op, @intFromEnum(wire.OpKind.share), 0, undecodable);
    const extended = try craftAnnounce(gpa, 72, "extended-doc", &.{ 0, 1, 2, 3 });
    defer gpa.free(extended);
    try sa.post(.op, @intFromEnum(wire.OpKind.share), 0, extended);

    var doc_b = try Document.init(gpa, "bob");
    defer doc_b.deinit(gpa);
    var opened = false;
    const deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < deadline) {
        _ = try ca.tick();
        _ = try cb.tick();
        if (!opened) {
            for (cb.offers.items, 0..) |o, i| {
                if (std.mem.eql(u8, o.name, "shared")) {
                    _ = try cb.openOffer(i, &doc_b, 1);
                    opened = true;
                    break;
                }
            }
        } else if (doc_b.text().byteLen() == doc_a.text().byteLen()) break;
        testPark(1);
    }
    try t.expect(opened);

    // The undecodable descriptor produced no offer at all — mis-reading it
    // as text would have bound the text driver to a surface it cannot
    // decode. The extended one is an ordinary text offer.
    var saw_extended = false;
    for (cb.offers.items) |o| {
        try t.expect(!std.mem.eql(u8, o.name, "future-doc"));
        if (std.mem.eql(u8, o.name, "extended-doc")) {
            saw_extended = true;
            try t.expectEqual(Conn.DocKind.text, o.kind);
        }
    }
    try t.expect(saw_extended);

    // And the peer is whole: the shared replica converged across the
    // unknown frame rather than stalling on it.
    try t.expectEqual(doc_a.text().byteLen(), doc_b.text().byteLen());
}

test "gate C (§18): a replica-only share emits nothing else; each selection lights exactly its channel" {
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

    var emitted: QuadEmissions = .{};
    sa.tap = emitted.tap();

    var ca = try Collab.init(gpa, sa, &doc_a, "alice");
    defer ca.deinit();
    var cb = try Collab.init(gpa, sb, &doc_b, "bob");
    defer cb.deinit();

    var layers: layers_mod.Layers = .empty;
    defer layers.deinit(gpa);
    const export_diag = try layers.claim(gpa, &doc_a, "diagnostics", .local, "gate");

    // Replica export only, with the caret moving the whole time.
    converge_a = &doc_a;
    converge_b = &doc_b;
    try t.expect(try pumpCollabsUntil(&ca, &cb, 3, convergedByLen));
    for (0..100) |i| {
        _ = try ca.tick(i % 8);
        _ = try cb.tick(0);
    }
    try t.expect(emitted.ops > 0);
    try t.expectEqual(@as(usize, 0), emitted.presence);
    try t.expectEqual(@as(usize, 0), emitted.diagnostics);

    // Presence lights base+1 and only base+1.
    try ca.setPublishPresence(true);
    const presence_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    var moved: usize = 0;
    while (task.nowNs() < presence_deadline and emitted.presence == 0) : (moved += 1) {
        _ = try ca.tick(moved % 8);
        _ = try cb.tick(0);
        testPark(1);
    }
    try t.expect(emitted.presence > 0);
    try t.expectEqual(@as(usize, 0), emitted.diagnostics);

    // Diagnostics light base+2 and only base+2.
    const before_presence = emitted.presence;
    try export_diag.appendSpan(gpa, .{ .start = 0, .end = 5, .kind = 1, .message = "unused" });
    ca.export_diag_layer = export_diag;
    const diag_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < diag_deadline and emitted.diagnostics == 0) {
        _ = try ca.tick(3);
        _ = try cb.tick(0);
        testPark(1);
    }
    try t.expect(emitted.diagnostics > 0);
    try t.expect(emitted.presence >= before_presence);
}

test "gate D (§18): a hierarchy-only peer lists names, and is refused every byte and every write" {
    const gpa = t.allocator;

    var pbuf: [128]u8 = undefined;
    const root_path = try std.fmt.bufPrintZ(&pbuf, "/tmp/weft-gate-d-{d}", .{linux.getpid()});
    _ = linux.rmdir(root_path.ptr);
    if (linux.errno(linux.mkdir(root_path.ptr, 0o755)) != .SUCCESS) return error.Mkdir;
    var root = try rooted_fs.RootedFs.open(root_path.ptr);
    defer root.close();
    defer {
        _ = linux.unlinkat(root.root_fd, "secret.txt", 0);
        _ = linux.rmdir(root_path.ptr);
    }
    try root.write("secret.txt", "classified");

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

    ch.peer_fs_root = &root;
    ch.fs_grant = .{ .hierarchy = true };
    var rfs = RemoteFs.init(gpa);
    defer rfs.deinit();
    cc.remote_fs = &rfs;

    // The hierarchy is granted: names cross.
    const list_req = try peer_fs.encodeList(gpa, ".");
    defer gpa.free(list_req);
    const listing = try callPeerFs(&ch, &cc, &rfs, sb, list_req);
    defer gpa.free(listing);
    try t.expectEqual(peer_fs.Status.ok, peer_fs.decodeResponse(listing).?.status);
    try t.expect(std.mem.indexOf(u8, peer_fs.decodeResponse(listing).?.payload, "secret.txt") != null);

    // The bytes are not, nor is a digest of them, nor is a write. Each
    // settles as a named refusal, well inside its deadline.
    const read_req = try peer_fs.encodeRead(gpa, "secret.txt");
    defer gpa.free(read_req);
    try t.expectError(error.RequestDenied, callPeerFs(&ch, &cc, &rfs, sb, read_req));
    {
        const stat_req = try peer_fs.encodeStat(gpa, "secret.txt");
        defer gpa.free(stat_req);
        try t.expectError(error.RequestDenied, callPeerFs(&ch, &cc, &rfs, sb, stat_req));
    }
    {
        const write_req = try peer_fs.encodeWrite(gpa, "secret.txt", peer_fs.tokenOf("classified"), "rewritten");
        defer gpa.free(write_req);
        try t.expectError(error.RequestDenied, callPeerFs(&ch, &cc, &rfs, sb, write_req));
    }
    {
        const on_disk = try root.read(gpa, "secret.txt");
        defer gpa.free(on_disk);
        try t.expectEqualStrings("classified", on_disk);
    }

    // The refusals are the EXPORT SET, not a broken path: adding the bytes
    // surface serves the same read over the same wire.
    ch.fs_grant = .read;
    const allowed = try callPeerFs(&ch, &cc, &rfs, sb, read_req);
    defer gpa.free(allowed);
    try t.expectEqual(peer_fs.Status.ok, peer_fs.decodeResponse(allowed).?.status);
    try t.expectEqualStrings("classified", peer_fs.decodeResponse(allowed).?.payload);
}

test "gate E (§18): revoking an export refuses the next batch and blocks the grantee's next mint" {
    const gpa = t.allocator;
    var rig: LeaseRig = undefined;
    try LeaseRig.setup(gpa, &rig);
    defer rig.deinit(gpa);

    var grant_table = grants.HandleTable.init(gpa);
    defer grant_table.deinit();
    rig.ga.bindGrants(&grant_table);
    _ = try rig.ga.grantSubtree(rig.room1);

    const announced_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < announced_deadline and rig.gb.granted_roots.len != 1) {
        try rig.pump();
        testPark(2);
    }
    try t.expectEqual(@as(usize, 1), rig.gb.granted_roots.len);
    const room1_obj = try rig.joiner.resolve(rig.room1);
    try t.expect(try rig.gb.mayEditNode(gpa, room1_obj));

    try t.expectEqual(@as(usize, 1), rig.ga.revokeSubtreeGrants());

    // The grantee's own preflight closes as soon as the retraction lands —
    // "narrowed to nothing" is not "never narrowed".
    const retracted_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < retracted_deadline and rig.gb.granted_roots.len != 0) {
        try rig.pump();
        testPark(2);
    }
    try t.expect(rig.gb.granted_confined);
    try t.expectEqual(@as(usize, 0), rig.gb.granted_roots.len);
    try t.expect(!(try rig.gb.mayEditNode(gpa, room1_obj)));

    // And a client that sends anyway — the announcement is advisory — is
    // refused at the host, in the region it just tried to edit.
    _ = try rig.joiner.set(gpa, room1_obj, "after-revocation", .{ .str = "no" });
    const refused_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (task.nowNs() < refused_deadline and rig.gb.refusals.items.len == 0) {
        try rig.pump();
        testPark(2);
    }
    try t.expect(rig.gb.refusals.items.len > 0);
    try t.expectEqual(GraphCollab.RefusalReason.authority, rig.gb.refusals.items[0].reason);
    try t.expect(rig.origin.ref(try rig.origin.resolve(rig.room1)).mapGet("after-revocation") == null);
}

// ── §14.4 gate: LSP as a granted publication export ─────────────────
// Typed language service over the wire — never forwarded JSON-RPC. The
// owner answers from its own language sessions through `peer_lsp.Service`;
// the peer holds (or does not hold) the `lsp` export.

const peer_lsp = @import("../peer_lsp.zig");
const RemoteLsp = remote_fs.RemoteLsp;

/// A hermetic owner-side language service: a fixed answer table, no server,
/// no protocol. Stands in for the multi-session table `src/guest/lsp.zig`
/// owns — this gate is about the EXPORT, not about zls.
const FakeLanguageService = struct {
    asked: usize = 0,
    last: peer_lsp.Op = .completion,
    completion: []const peer_lsp.Item = &.{},
    definition: []const peer_lsp.Location = &.{},

    pub fn answer(self: *FakeLanguageService, _: Allocator, req: peer_lsp.Request) Allocator.Error!?peer_lsp.Answer {
        self.asked += 1;
        self.last = req.op;
        return switch (req.op) {
            .completion => .{ .items = self.completion },
            .definition => .{ .locations = self.definition },
            else => null,
        };
    }
};

/// Two in-process sessions over a socketpair, the owner exporting a typed
/// language service for one published document.
const LspPair = struct {
    fds: [2]i32,
    la: FdLink,
    lb: FdLink,
    host: Document,
    client: Document,
    sa: *Session,
    sb: *Session,
    ch: Collab,
    cc: Collab,
    rl: RemoteLsp,

    fn init(
        gpa: Allocator,
        self: *LspPair,
        service: *FakeLanguageService,
        grant: peer_lsp.Grant,
        documents: []const []const u8,
    ) !void {
        self.fds = try socketPair();
        self.la = .{ .fd = self.fds[0] };
        self.lb = .{ .fd = self.fds[1] };
        self.host = try Document.init(gpa, "host");
        self.client = try Document.init(gpa, "client");
        self.sa = try Session.create(gpa, self.la.link(), .server, "tok", .own, null);
        self.sb = try Session.create(gpa, self.lb.link(), .client, "tok", .own, null);
        self.ch = try Collab.init(gpa, self.sa, &self.host, "host");
        self.cc = try Collab.init(gpa, self.sb, &self.client, "client");
        self.rl = RemoteLsp.init(gpa);
        self.ch.lsp_grant = grant;
        self.ch.lsp_documents = .{ .names = documents };
        self.ch.peer_lsp_service = peer_lsp.Service.init(service);
        self.cc.remote_lsp = &self.rl;
        var settle: usize = 0;
        while (settle < 80) : (settle += 1) self.turn();
    }

    fn deinit(self: *LspPair, gpa: Allocator) void {
        self.rl.deinit();
        self.cc.deinit();
        self.ch.deinit();
        self.sb.destroy();
        self.sa.destroy();
        self.client.deinit(gpa);
        self.host.deinit(gpa);
    }

    fn turn(self: *LspPair) void {
        _ = self.ch.tick(0) catch {};
        _ = self.cc.tick(0) catch {};
        futexWaitTimed(&self.sb.out_wake, self.sb.out_wake.load(.acquire), std.time.ns_per_ms);
    }

    /// Ask one typed question and drive both ends until it settles.
    fn ask(self: *LspPair, gpa: Allocator, req: peer_lsp.Request) requests.Error!?[]u8 {
        const bytes = peer_lsp.encodeRequest(gpa, req) catch return null;
        defer gpa.free(bytes);
        const id = self.rl.request(self.sb, self.cc.base, bytes) catch return null;
        const guard = task.nowNs() + 5 * std.time.ns_per_s;
        while (task.nowNs() < guard) {
            if (try self.rl.take(id)) |response| return response;
            self.turn();
        }
        return null;
    }
};

test "lsp export: a peer holding the grant gets a real completion answer over the wire, as typed items" {
    const gpa = t.allocator;
    var service: FakeLanguageService = .{ .completion = &.{
        .{ .text = "parseHeader", .label = "parseHeader(bytes)", .detail = "fn", .kind = 3, .rank = 1 },
        .{ .text = "parseBody", .kind = 3, .rank = 2 },
    } };
    var pair: LspPair = undefined;
    try LspPair.init(gpa, &pair, &service, .all, &.{"parser.zig"});
    defer pair.deinit(gpa);

    const resp = (try pair.ask(gpa, .{
        .op = .completion,
        .document = "parser.zig",
        .offset = 42,
        .text = "pars",
    })).?;
    defer gpa.free(resp);

    const reply = peer_lsp.decodeReply(resp).?;
    try t.expectEqual(peer_lsp.Status.ok, reply.status);
    var it = peer_lsp.items(reply.body);
    const first = it.next().?;
    try t.expectEqualStrings("parseHeader", first.text);
    try t.expectEqualStrings("parseHeader(bytes)", first.label);
    try t.expectEqual(@as(u8, 3), first.kind);
    try t.expectEqualStrings("parseBody", it.next().?.text);
    try t.expectEqual(@as(?peer_lsp.Item, null), it.next());

    // The owner answered from ITS language sessions, and what crossed the
    // wire is the typed vocabulary — no JSON-RPC in either direction.
    try t.expectEqual(@as(usize, 1), service.asked);
    try t.expectEqual(peer_lsp.Op.completion, service.last);
    try t.expect(std.mem.indexOf(u8, resp, "jsonrpc") == null);
    try t.expect(std.mem.indexOf(u8, resp, "textDocument/") == null);
}

test "lsp export: the same ask without the grant refuses TYPED, and the owner's language sessions are never reached" {
    const gpa = t.allocator;
    var service: FakeLanguageService = .{ .completion = &.{.{ .text = "parseHeader" }} };
    var pair: LspPair = undefined;
    try LspPair.init(gpa, &pair, &service, .none, &.{"parser.zig"});
    defer pair.deinit(gpa);

    // "You may not ask" settles now, by name — not a deadline the requester
    // sits out, and never an empty answer that reads as "nothing found".
    try t.expectError(error.RequestDenied, pair.ask(gpa, .{
        .op = .completion,
        .document = "parser.zig",
        .offset = 42,
        .text = "pars",
    }));
    try t.expectEqual(@as(usize, 0), service.asked);

    // The refusal is the EXPORT, not a broken path: granting it answers the
    // identical question over the identical wire.
    pair.ch.lsp_grant = .all;
    const resp = (try pair.ask(gpa, .{
        .op = .completion,
        .document = "parser.zig",
        .offset = 42,
        .text = "pars",
    })).?;
    defer gpa.free(resp);
    try t.expectEqual(peer_lsp.Status.ok, peer_lsp.decodeReply(resp).?.status);
    try t.expectEqual(@as(usize, 1), service.asked);
}

test "lsp export: a definition outside the granted document set is withheld owner-side (and logged); the in-set results still answer" {
    const gpa = t.allocator;
    var service: FakeLanguageService = .{ .definition = &.{
        .{ .document = "parser.zig", .start = 10, .end = 21 },
        .{ .document = "private.zig", .start = 0, .end = 4 },
    } };
    var pair: LspPair = undefined;
    try LspPair.init(gpa, &pair, &service, .all, &.{"parser.zig"});
    defer pair.deinit(gpa);

    const resp = (try pair.ask(gpa, .{
        .op = .definition,
        .document = "parser.zig",
        .offset = 12,
        .text = "",
    })).?;
    defer gpa.free(resp);

    const reply = peer_lsp.decodeReply(resp).?;
    try t.expectEqual(peer_lsp.Status.ok, reply.status);
    var it = peer_lsp.locations(reply.body);
    const only = it.next().?;
    try t.expectEqualStrings("parser.zig", only.document);
    try t.expectEqual(@as(u64, 10), only.start);
    try t.expectEqual(@as(?peer_lsp.Location, null), it.next());
    // Withheld means the peer never learns the document EXISTS: its name is
    // nowhere in the bytes that crossed (`peer_lsp.putLocations` writes the
    // one line owner-side).
    try t.expect(std.mem.indexOf(u8, resp, "private.zig") == null);

    // A question ABOUT a document outside the set is refused on its own
    // terms, without reaching the language sessions at all.
    const before = service.asked;
    const outside = (try pair.ask(gpa, .{
        .op = .definition,
        .document = "private.zig",
        .offset = 0,
        .text = "",
    })).?;
    defer gpa.free(outside);
    try t.expectEqual(peer_lsp.Status.out_of_scope, peer_lsp.decodeReply(outside).?.status);
    try t.expectEqual(before, service.asked);
}
