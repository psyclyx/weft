//! Collaboration state + wiring + frame-loop appliers. `ShareCtx` is the
//! shared state commands record intents on; `applyIntents` (run in the frame
//! loop, outside the input hot section) acts on them — connect blocks on TCP,
//! disconnect joins session threads. Outbound is a single client `Conn`;
//! inbound hosting is an additive `Hub` accepting N peers. The command
//! handlers that poke this state live in `collab_cmds.zig`.

const std = @import("std");
const core = @import("../core/core.zig");
const window_layout = @import("../gfx/window_layout.zig");
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

/// `Collab` — the cohesive owner of the connection cluster: the outbound client
/// (`conn`/`collab_session`/`partial_state`), the inbound host (`hub`), the
/// opt-in shared filesystem + async `.peer` fs bridge, the `ShareCtx` intent
/// surface, and the frame-loop liveness/reconnect/interactive-connect state.
/// `main()` holds ONE `collab` object instead of ~16 loose connection locals.
///
/// Built IN PLACE (like `Session`/`RenderState`): `share_ctx` points at sibling
/// fields (`&self.conn`, `&self.hub`, `&self.partial_state`, …) and the async
/// `.peer` bridge registers its own address as a process-global, so `self` must
/// already sit at its final `main()` address. `initBase` lays the skeleton (all
/// optionals null, the fs bridge, the share surface) and registers the deinit;
/// `connect` then fills the outbound optionals when `--connect` was given, with
/// the pre-registered deinit cleaning any partial state on error (mirroring how
/// `main()` deferred the optionals before the connect block filled them).
///
/// `deinit` frees in the EXACT reverse order `main()`'s ~13 connection defers
/// used to run — the whole reason this is a distinct, carefully-ordered cluster.
/// It runs BEFORE the provider detach (conn/hub teardown must precede the doc
/// layer drop) and before `Session` (it reads the session caps), which `main()`
/// guarantees by registering it right after the detach defer.
///
/// NOT owned here (deliberately): `known_peers` and `my_identity` stay `main()`
/// locals — they are built early (the `identity` command binds `my_identity`,
/// registered before config for last-wins order) and their teardown is
/// independent, so folding them in would either regress early-error leak-safety
/// or force conn/hub teardown past the detach. `share_ctx.known` borrows the
/// former; `connect` borrows the latter.
pub const Collab = struct {
    gpa: std.mem.Allocator,

    // ── Outbound client (--connect) + inbound host (--listen) + partial ──
    fd_link: core.session.FdLink,
    collab_session: ?*core.session.Session,
    conn: ?core.session.Conn,
    partial_state: ?core.session.PartialDoc,
    hub: ?core.hub.Hub,

    // ── Opt-in filesystem sharing + the async .peer fs bridge ──
    peer_fs_root: ?core.rooted_fs.RootedFs,
    remote_fs: core.session.RemoteFs,
    peer_fs_bridge: core.wasm_host.PeerFsBridge,
    peer_fs_inflight: std.AutoHashMapUnmanaged(u64, []u8),

    // ── The share intent surface (self-referential: points at siblings) ──
    share_ctx: ShareCtx,

    // ── Frame-loop liveness / reconnect / interactive-connect state ──
    last_liveness: core.session.Liveness,
    noted_host_fp: ?[24]u8,
    reconnect: ?core.task.Handle(anyerror!i32),
    connect_task: ?core.task.Handle(anyerror!i32),
    connect_hostport: ?[]u8,
    next_reconnect_ns: u64,

    /// Lay the skeleton IN PLACE: all optionals null, the fs bridge registered as
    /// the process-global, the share surface pointing at sibling fields, the boot
    /// --listen intent seeded. Infallible — nothing here can leak — so `main()`
    /// registers `deinit` immediately after, then runs `connect`.
    pub fn initBase(
        self: *Collab,
        gpa: std.mem.Allocator,
        buffers: *core.Buffers,
        caps: *core.Caps,
        known: *core.known_peers.KnownPeers,
        share_root: ?[]const u8,
        share_fs: core.peer_fs.Access,
        listen: ?u16,
        access: core.session.Access,
    ) void {
        self.gpa = gpa;
        self.fd_link = undefined;
        self.collab_session = null;
        self.conn = null;
        self.partial_state = null;
        self.hub = null;
        // Opt-in filesystem sharing (host side): a confined root served to peers.
        // Default off — a peer gets nothing unless the host passed --share-root.
        self.peer_fs_root = null;
        if (share_root) |root_dir| {
            if (gpa.dupeZ(u8, root_dir)) |rz| {
                defer gpa.free(rz);
                self.peer_fs_root = core.rooted_fs.RootedFs.open(rz.ptr) catch blk: {
                    std.log.warn("share-root: cannot open '{s}'", .{root_dir});
                    break :blk null;
                };
            } else |_| {}
        }
        // Client side: correlate .peer fs replies, and the bridge the guest queues
        // async LIST requests through (dired-on-a-peer).
        self.remote_fs = core.session.RemoteFs.init(gpa);
        self.peer_fs_bridge = .{ .gpa = gpa };
        core.wasm_host.setPeerFsBridge(&self.peer_fs_bridge);
        self.peer_fs_inflight = .empty;
        self.share_ctx = .{
            .conn = &self.conn,
            .hub = &self.hub,
            .caps = caps,
            .gpa = gpa,
            .buffers = buffers,
            .partial = &self.partial_state,
            .session = &self.collab_session,
            .known = known,
            .peer_fs_root = if (self.peer_fs_root) |*r| r else null,
            .fs_grant = .{ .access = share_fs },
        };
        // Boot --listen folds onto the runtime listen path (one code path): seed
        // the intent; the first frame boots the hub.
        if (listen) |port| {
            self.share_ctx.pending_listen = port;
            self.share_ctx.pending_access = access;
        }
        self.last_liveness = .connecting;
        self.noted_host_fp = null;
        self.reconnect = null;
        self.connect_task = null;
        self.connect_hostport = null;
        self.next_reconnect_ns = 0;
    }

    /// Fill the outbound optionals when `--connect` was given: TCP-connect, build
    /// the client session + Conn, bind buffer 0 (wire v1) and claim its presence
    /// + host-diagnostics layers. A partial checkout keeps the doc virgin.
    /// Runs after `initBase` (so the pre-registered `deinit` cleans partial state
    /// on error, exactly as `main()`'s pre-deferred optionals did).
    pub fn connect(
        self: *Collab,
        gpa: std.mem.Allocator,
        ed0: *core.Editor,
        caps: *core.Caps,
        my_identity: *const core.identity.Identity,
        hostport: ?[]const u8,
        token: []const u8,
        user: []const u8,
        partial: bool,
    ) !void {
        const hp = hostport orelse return;
        self.fd_link = .{ .fd = try core.session.tcpConnect(hp) };
        self.collab_session = try core.session.Session.create(gpa, self.fd_link.link(), .client, token, .own, my_identity);
        self.conn = try core.session.Conn.init(gpa, self.collab_session.?, user, .client);
        const col = try self.conn.?.bindPrimary(&ed0.doc, 0);
        col.presence_layer = try caps.layers.claim(gpa, &ed0.doc, "presence", .replicated, "collab");
        // Host-scoped feeds (diagnostics) arrive over the wire.
        col.import_diag_layer = try caps.layers.claim(gpa, &ed0.doc, "diagnostics", .host, "remote-host");
        col.remote_fs = &self.remote_fs; // client can list/read the host's shared root
        if (partial) {
            self.partial_state = core.session.PartialDoc.init(gpa, &ed0.doc);
            col.partial = &self.partial_state.?;
        }
    }

    /// Free in the EXACT reverse order `main()`'s connection defers used to run:
    /// detach the in-flight connect handles; drop the share intents; free the
    /// pending peer-fs listings; clear the process-global bridge then free it;
    /// remote_fs; the shared fs root; then hub, partial, conn, session. Runs
    /// before the provider detach + Session teardown (main() orders it so).
    pub fn deinit(self: *Collab, gpa: std.mem.Allocator) void {
        // In-flight interactive connect / self-reconnect: detach (a worker may
        // still borrow connect_hostport → a bounded, one-shot leak).
        if (self.connect_task) |*h| h.detach();
        if (self.reconnect) |*h| h.detach();
        for (self.share_ctx.shared.items) |s| gpa.free(s.name);
        self.share_ctx.shared.deinit(gpa);
        if (self.share_ctx.pending_connect) |hp| gpa.free(hp);
        {
            var pit = self.peer_fs_inflight.valueIterator();
            while (pit.next()) |v| gpa.free(v.*);
            self.peer_fs_inflight.deinit(gpa);
        }
        core.wasm_host.setPeerFsBridge(null);
        self.peer_fs_bridge.deinit();
        self.remote_fs.deinit();
        if (self.peer_fs_root) |*r| r.close();
        if (self.hub) |*h| h.deinit();
        if (self.partial_state) |*p| p.deinit();
        if (self.conn) |*c| c.deinit();
        if (self.collab_session) |s| s.destroy();
    }
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

/// The collab TICK (run each frame, after intents are applied): adopt new hub
/// peers and publish/relay their cursors; publish our own cursors on the
/// outbound conn; drive the partial checkout's fetch window per pane; pump the
/// async .peer filesystem; note the host's identity once per handshake; and
/// self-reconnect a flapping client link. Most state comes from `sc`; the
/// remaining frame-loop locals are threaded by pointer (they live in `main()`,
/// which owns them). Returns whether the view was damaged.
pub fn tickCollab(
    sc: *ShareCtx,
    cmd_ctx: *core.command.Context,
    ed0: *core.Editor,
    win_layout: *window_layout.Layout,
    peer_fs_bridge: *core.wasm_host.PeerFsBridge,
    remote_fs: *core.session.RemoteFs,
    peer_fs_inflight: *std.AutoHashMapUnmanaged(u64, []u8),
    noted_host_fp: *?[24]u8,
    last_liveness: *core.session.Liveness,
    reconnect: *?core.task.Handle(anyerror!i32),
    next_reconnect_ns: *u64,
    fd_link: *core.session.FdLink,
    my_identity: *const core.identity.Identity,
    pool: *core.task.Pool,
    connect: ?[]const u8,
    token: []const u8,
    echo: *std.ArrayList(u8),
) !bool {
    const gpa = sc.gpa;
    var dirty = false;
    if (sc.hub.*) |*h| {
        // Adopt new peers (binds the primary + replays shares), then
        // publish the local cursor to every peer and tick.
        h.acceptPending(sc, guiConfigure);
        for (h.clients.items) |peer| {
            for (peer.conn.collabs.items) |col| {
                if (sc.buffers.get(@intCast(col.tag))) |b| {
                    col.cursor_offset = b.editor.cursorOffset();
                    col.selection_anchor = selectionAnchorOf(&b.editor);
                }
            }
        }
        if (h.tick()) dirty = true;
        // Merge every peer's cursor into each shared doc's presence
        // layer for local display (per-peer collabs keep it null).
        if (sc.primary_doc) |pd| {
            if (sc.caps.layers.find(pd, "presence")) |pl| core.hub.unionPresence(h, pd, pl, gpa) catch {};
        }
        for (sc.shared.items) |s| {
            if (sc.caps.layers.find(s.doc, "presence")) |pl| core.hub.unionPresence(h, s.doc, pl, gpa) catch {};
        }
    }

    if (sc.conn.*) |*c| {
        // Each bound buffer publishes its own cursor + selection.
        for (c.collabs.items) |col| {
            if (sc.buffers.get(@intCast(col.tag))) |b| {
                col.cursor_offset = b.editor.cursorOffset();
                col.selection_anchor = selectionAnchorOf(&b.editor);
            }
        }
        // Partial checkout: realize content around the cursor (the
        // requests dedupe against realized + inflight spans). Also want
        // the scroll window of every pane rendering the partial buffer
        // (buffer 0, wire v1) — a split peeking it elsewhere must not
        // read an unrealized hole (see partial_blocked below).
        if (sc.partial.*) |*p| {
            const cur = ed0.cursorOffset();
            p.want(sc.session.*.?, 0, cur -| (64 << 10), cur + (128 << 10)) catch {};
            const WantCtx = struct { p: *core.session.PartialDoc, sess: *core.session.Session, ed0: *core.Editor };
            win_layout.eachPane(WantCtx{ .p = p, .sess = sc.session.*.?, .ed0 = ed0 }, struct {
                fn visit(wc: WantCtx, pane: *window_layout.Pane) void {
                    if (pane.buffer_id != 0) return; // the partial doc is buffer 0
                    const rope = wc.ed0.text();
                    const rows = rope.lineCount();
                    if (rows == 0) return;
                    const start = rope.lineRange(@min(pane.top_row, rows - 1)).start;
                    wc.p.want(wc.sess, 0, start -| (8 << 10), start + (128 << 10)) catch {};
                }
            }.visit);
        }
        if (try c.tick()) dirty = true;
        // Async .peer fs: post the guest's queued LIST requests over the
        // session, then deliver any completed listings into their buffers.
        if (sc.session.*) |sess| {
            for (peer_fs_bridge.requests.items) |req| {
                defer gpa.free(req.path);
                const enc = core.peer_fs.encodeList(gpa, req.path) catch {
                    gpa.free(req.dest);
                    continue;
                };
                defer gpa.free(enc);
                if (remote_fs.request(sess, 0, enc)) |id| {
                    peer_fs_inflight.put(gpa, id, req.dest) catch gpa.free(req.dest);
                } else |_| gpa.free(req.dest);
            }
            peer_fs_bridge.requests.clearRetainingCapacity();
            var done: [16]u64 = undefined;
            var dn: usize = 0;
            var pit = peer_fs_inflight.iterator();
            while (pit.next()) |e| {
                if (remote_fs.take(e.key_ptr.*)) |resp| {
                    defer gpa.free(resp);
                    if (core.peer_fs.decodeResponse(resp)) |dec| {
                        if (dec.status == .ok)
                            core.wasm_host.deliverToBuffer(cmd_ctx, e.value_ptr.*, "peer-fs", dec.payload);
                    }
                    gpa.free(e.value_ptr.*);
                    if (dn < done.len) {
                        done[dn] = e.key_ptr.*;
                        dn += 1;
                    }
                    dirty = true;
                }
            }
            for (done[0..dn]) |id| _ = peer_fs_inflight.remove(id);
        }
        // Note the host's identity once per handshake: TOFU-record it
        // and echo its fingerprint + SAS + trust so the user can verify
        // the four words out of band before trusting a new host.
        if (sc.session.*.?.peerFingerprint()) |fp| {
            if (noted_host_fp.* == null or !std.mem.eql(u8, &noted_host_fp.*.?, &fp)) {
                noted_host_fp.* = fp;
                const prior = sc.known.remember(fp) catch core.known_peers.Trust.unknown;
                const sas = sc.session.*.?.sas().?; // established ⇒ present
                var buf: [96]u8 = undefined;
                const msg = if (prior == .verified)
                    std.fmt.bufPrint(&buf, "host {s} · verified", .{&fp}) catch "host verified"
                else
                    std.fmt.bufPrint(&buf, "host {s} · unverified · SAS {s}", .{ &fp, &sas }) catch "host unverified";
                setEcho(echo, gpa, msg);
                std.log.info("collab: {s}", .{msg});
                dirty = true;
            }
        }
        const live = sc.session.*.?.liveness();
        if (live != last_liveness.*) {
            last_liveness.* = live;
            dirty = true;
        }
        // A flapping link reconnects itself (client role): pooled
        // connect attempts every 3s, rebind on success — the resync
        // is the ordinary frontier exchange (+ share re-announce).
        if (live == .offline and connect != null) {
            if (reconnect.*) |*h| {
                if (h.poll()) |res| {
                    reconnect.* = null;
                    if (res) |fd| {
                        sc.session.*.?.destroy();
                        fd_link.* = .{ .fd = fd };
                        sc.session.* = try core.session.Session.create(gpa, fd_link.link(), .client, token, .own, my_identity);
                        try c.rebind(sc.session.*.?);
                        std.log.info("collab: reconnected", .{});
                        dirty = true;
                    } else |_| {
                        next_reconnect_ns.* = core.task.nowNs() + 3 * std.time.ns_per_s;
                    }
                }
            } else if (core.task.nowNs() >= next_reconnect_ns.*) {
                next_reconnect_ns.* = core.task.nowNs() + 3 * std.time.ns_per_s;
                reconnect.* = try pool.spawn(reconnectTask, .{connect.?});
            }
        }
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
