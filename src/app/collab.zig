//! Collaboration state + wiring + frame-loop appliers. `ShareCtx` is the
//! shared state commands record intents on; `applyIntents` (run in the frame
//! loop, outside the input hot section) acts on them — connect blocks on TCP,
//! disconnect joins session threads. Outbound is a single client `Conn`;
//! inbound hosting is an additive `Hub` accepting N peers. The command
//! handlers that poke this state live in `collab_cmds.zig`.

const std = @import("std");
const core = @import("../core/core.zig");
const setEcho = @import("handler.zig").setEcho;

/// Status-line chip for a peer's trust grade (null = don't show).
pub fn hostTrustChip(trust: core.known_peers.Trust) ?[]const u8 {
    return switch (trust) {
        .verified => "✓ verified",
        .unverified => "⚠ unverified",
        .unknown => "⚠ unknown",
    };
}

/// The far end of the editor's selection (the end that is not the caret),
/// or the caret itself when nothing is selected — what presence publishes
/// so peers can render our selection, not just our cursor.
pub fn selectionAnchorOf(ed: *const core.Editor) usize {
    const cur = ed.cursorOffset();
    if (ed.selectedRange()) |r| return if (cur == r.start) r.end else r.start;
    return cur;
}

// ── Buffer sharing over the connection ──────────────────────────────

/// A buffer shared over the hub, remembered so late-joining peers can be
/// caught up (the hub analog of `Conn.share_names`). `name` is owned.
pub const SharedDoc = struct {
    doc: *core.Document,
    name: []u8,
    tag: u64,
};

pub const ShareCtx = struct {
    gpa: std.mem.Allocator,
    buffers: *core.Buffers,
    /// Outbound client connection (connect/--connect); single.
    conn: *?core.session.Conn,
    /// Inbound hosting: N peers (listen/--listen); additive.
    hub: *?core.hub.Hub,
    caps: *core.Caps,
    partial: *?core.session.PartialDoc,
    /// Outbound host session (for the `peers` command's fp/SAS/trust).
    session: *?*core.session.Session = undefined,
    /// TOFU store, for trust lookups in the `peers` command.
    known: *core.known_peers.KnownPeers = undefined,
    /// Buffers shared over the hub — replayed to late joiners.
    shared: std.ArrayList(SharedDoc) = .empty,
    /// The doc bound at quad 0 for every hub peer (the buffer active
    /// when listening began); set by the listen apply block.
    primary_doc: ?*core.Document = null,
    primary_tag: u64 = 0,
    /// Opt-in filesystem sharing (--share-root/--share-fs): a confined root
    /// served to peers, and the grant. Null root ⇒ serve no fs (default).
    peer_fs_root: ?*core.rooted_fs.RootedFs = null,
    fs_grant: core.peer_fs.Grant = .{},
    /// Commands record INTENTS here; the frame loop applies them
    /// outside the input hot section (connect blocks on TCP, disconnect
    /// joins session threads).
    pending_connect: ?[]u8 = null,
    disconnect_requested: bool = false,
    pending_listen: ?u16 = null,
    /// Access grade for the next `listen` (safe default: view).
    pending_access: core.session.Access = .view,
    stop_listen_requested: bool = false,
    /// C-g: drop queued connect/listen intents and abort an in-flight
    /// connect. Applied in the frame loop (which owns the connect handle).
    cancel_requested: bool = false,
};

/// Wire a hub-side collab as a participant-and-relay: no local presence
/// layer (the frame loop unions all peers into one), publish our own
/// cursor, relay peers to each other.
pub fn wireHubShare(sc: *ShareCtx, peer: *core.hub.Peer, col: *core.session.Collab, doc: *core.Document) !void {
    col.presence_layer = null;
    col.export_diag_layer = sc.caps.layers.find(doc, "diagnostics");
    col.publish_presence = true;
    col.relay = core.hub.relayPresence;
    col.relay_ctx = try peer.relayFor(doc);
    // Serve the opt-in shared filesystem root to this peer (default: none, so a
    // peer gets nothing unless the host passed --share-root/--share-fs).
    col.peer_fs_root = sc.peer_fs_root;
    col.fs_grant = sc.fs_grant;
}

/// Bind a newly joined hub peer: the primary doc at quad 0, then replay
/// every already-shared buffer so late joiners are caught up.
pub fn guiConfigure(ctx: ?*anyopaque, peer: *core.hub.Peer) anyerror!void {
    const sc: *ShareCtx = @ptrCast(@alignCast(ctx.?));
    const pd = sc.primary_doc orelse return error.NoPrimary;
    const col = try peer.conn.bindPrimary(pd, sc.primary_tag);
    try wireHubShare(sc, peer, col, pd);
    _ = sc.caps.layers.claim(sc.gpa, pd, "presence", .replicated, "collab") catch {};
    for (sc.shared.items) |s| {
        const scol = try peer.conn.share(s.doc, s.name, s.tag);
        try wireHubShare(sc, peer, scol, s.doc);
        _ = sc.caps.layers.claim(sc.gpa, s.doc, "presence", .replicated, "collab") catch {};
    }
}

/// Start the hub: assign into the slot FIRST, then `listen` against the
/// slot's stable address (the accept thread captures it).
pub fn startListen(
    gpa: std.mem.Allocator,
    hub_slot: *?core.hub.Hub,
    sc: *ShareCtx,
    buffers: *core.Buffers,
    caps: *core.Caps,
    port: u16,
    token: []const u8,
    access: core.session.Access,
    my_identity: *const core.identity.Identity,
    echo: *std.ArrayList(u8),
) void {
    sc.primary_doc = &buffers.active().editor.doc;
    sc.primary_tag = buffers.active_id;
    hub_slot.* = core.hub.Hub.init(gpa, token, access, my_identity) catch {
        setEcho(echo, gpa, "listen: out of memory");
        return;
    };
    const h = &hub_slot.*.?;
    h.listen(port) catch |err| {
        var buf: [64]u8 = undefined;
        setEcho(echo, gpa, std.fmt.bufPrint(&buf, "listen failed: {t}", .{err}) catch "listen failed");
        h.deinit();
        hub_slot.* = null;
        return;
    };
    _ = caps.layers.claim(gpa, sc.primary_doc.?, "presence", .replicated, "collab") catch {};
    var buf: [32]u8 = undefined;
    setEcho(echo, gpa, std.fmt.bufPrint(&buf, "listening on {d}", .{port}) catch "listening");
}

/// Pooled TCP connect (a copy of providers.reconnectTask, kept local so
/// collab need not import providers — providers already imports collab).
fn reconnectTask(hostport: []const u8) anyerror!i32 {
    return core.session.tcpConnect(hostport);
}

/// Apply the connect/disconnect/listen intents recorded by commands. Run in
/// the frame loop, OUTSIDE the input hot section: connect blocks on TCP,
/// disconnect joins session threads. Operates through `sc` (which bundles
/// conn/hub/partial/session/caps/buffers/gpa); the in-flight connect handle,
/// its borrowed hostport, and the fd_link live in the frame loop and are
/// threaded by pointer. Returns whether the view was damaged.
pub fn applyIntents(
    sc: *ShareCtx,
    cmd_ctx: *core.command.Context,
    pool: *core.task.Pool,
    connect_task: *?core.task.Handle(anyerror!i32),
    connect_hostport: *?[]u8,
    fd_link: *core.session.FdLink,
    echo: *std.ArrayList(u8),
    my_identity: *const core.identity.Identity,
    token: []const u8,
    user: []const u8,
) bool {
    const gpa = sc.gpa;
    var dirty = false;
    if (sc.disconnect_requested) {
        sc.disconnect_requested = false;
        if (sc.conn.*) |*c| {
            c.deinit();
            sc.conn.* = null;
        }
        if (sc.partial.*) |*p| {
            p.deinit();
            sc.partial.* = null;
        }
        if (sc.session.*) |s| {
            s.destroy();
            sc.session.* = null;
        }
        dirty = true;
    }
    if (sc.cancel_requested) {
        sc.cancel_requested = false;
        if (sc.pending_connect) |hp| {
            gpa.free(hp);
            sc.pending_connect = null;
        }
        sc.pending_listen = null;
        if (connect_task.*) |*h| {
            h.detach(); // worker still borrows connect_hostport → leak it
            connect_task.* = null;
            connect_hostport.* = null;
            setEcho(echo, gpa, "canceled");
        }
        dirty = true;
    }
    if (sc.pending_connect) |hostport| {
        sc.pending_connect = null;
        // Already connected or connecting → drop the request. Otherwise
        // kick the TCP connect onto the pool (never on the frame thread).
        if (sc.session.* != null or connect_task.* != null) {
            gpa.free(hostport);
        } else if (pool.spawn(reconnectTask, .{hostport})) |h| {
            connect_task.* = h;
            connect_hostport.* = hostport; // freed when the handle is polled
            setEcho(echo, gpa, "connecting…");
        } else |_| {
            gpa.free(hostport);
            setEcho(echo, gpa, "connect: out of memory");
        }
        dirty = true;
    }
    // Finish an in-flight interactive connect once the socket is up.
    if (connect_task.*) |*h| {
        if (h.poll()) |res| {
            connect_task.* = null;
            const hp = connect_hostport.*.?;
            defer {
                gpa.free(hp);
                connect_hostport.* = null;
            }
            if (res) |fd| {
                runtimeConnectFinish(gpa, cmd_ctx, sc.session, sc.conn, fd_link, fd, hp, token, user, sc.caps, my_identity) catch |err| {
                    _ = std.os.linux.close(fd);
                    var buf: [96]u8 = undefined;
                    setEcho(echo, gpa, std.fmt.bufPrint(&buf, "connect failed: {t}", .{err}) catch "connect failed");
                };
            } else |err| {
                var buf: [96]u8 = undefined;
                setEcho(echo, gpa, std.fmt.bufPrint(&buf, "connect failed: {t}", .{err}) catch "connect failed");
            }
            dirty = true;
        }
    }
    // Listen intents (same out-of-hot-section region): bind/listen
    // are immediate, accept runs on the hub's own thread.
    if (sc.pending_listen) |port| {
        sc.pending_listen = null;
        if (sc.hub.* == null) startListen(gpa, sc.hub, sc, sc.buffers, sc.caps, port, token, sc.pending_access, my_identity, echo);
        dirty = true;
    }
    if (sc.stop_listen_requested) {
        sc.stop_listen_requested = false;
        if (sc.hub.*) |*h| h.stopAccepting();
        dirty = true;
    }
    return dirty;
}

/// Finish a runtime connect from an already-open socket `fd` (the TCP
/// connect ran on the pool). Builds the client session + Conn and a
/// buffer for the remote primary.
pub fn runtimeConnectFinish(
    gpa: std.mem.Allocator,
    ctx: *core.command.Context,
    session_slot: *?*core.session.Session,
    conn_slot: *?core.session.Conn,
    fd_link: *core.session.FdLink,
    fd: i32,
    hostport: []const u8,
    token: []const u8,
    user: []const u8,
    caps: *core.Caps,
    my_identity: *const core.identity.Identity,
) !void {
    fd_link.* = .{ .fd = fd };
    const sess = try core.session.Session.create(gpa, fd_link.link(), .client, token, .own, my_identity);
    errdefer sess.destroy();
    var c = try core.session.Conn.init(gpa, sess, user, .client);
    errdefer c.deinit();

    const display = try std.fmt.allocPrint(gpa, "@{s}", .{hostport});
    defer gpa.free(display);
    const id = try ctx.buffers.create(gpa, display);
    const buf = ctx.buffers.get(id).?;
    const col = try c.bindPrimary(&buf.editor.doc, id);
    col.presence_layer = try caps.layers.claim(gpa, &buf.editor.doc, "presence", .replicated, "collab");
    col.import_diag_layer = try caps.layers.claim(gpa, &buf.editor.doc, "diagnostics", .host, "remote-host");
    session_slot.* = sess;
    conn_slot.* = c;
    try ctx.buffers.switchTo(gpa, id, ctx.keymap);
    std.log.info("connected to {s}", .{hostport});
}
