//! Collaboration: the whole share/connect/listen cluster. `ShareCtx` is the
//! shared state commands record intents on; the frame loop applies them
//! outside the input hot section (connect blocks on TCP, disconnect joins
//! session threads). Outbound is a single client `Conn`; inbound hosting is an
//! additive `Hub` accepting N peers. Presence (cursor/selection), trust (TOFU
//! fingerprints + SAS), and buffer offers all flow through here.

const std = @import("std");
const core = @import("../core/core.zig");
const handler = @import("handler.zig");
const ok_echo = handler.ok_echo;
const setEcho = handler.setEcho;

// ── Peer trust + identity ───────────────────────────────────────────

/// `peers` — echo/log every connected peer's fingerprint, four-word SAS,
/// and trust grade, so a user can compare the SAS out of band and then
/// `verify-peer <fingerprint>`. The full detail goes to the log (many
/// peers won't fit the status line); the echo is a one-line summary.
pub fn peersHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    var count: usize = 0;
    var first_line: ?[]const u8 = null;
    var line_buf: [160]u8 = undefined;

    const report = struct {
        fn one(kp: *core.known_peers.KnownPeers, sess: *core.session.Session, role: []const u8, n: *usize, fl: *?[]const u8, lb: []u8) void {
            const fp = sess.peerFingerprint() orelse return;
            const sas = sess.sas() orelse return;
            n.* += 1;
            const trust = kp.trust(fp);
            std.log.info("peer {s}: {s} · SAS {s} · {s}", .{ role, &fp, &sas, trust.label() });
            if (fl.* == null) {
                fl.* = std.fmt.bufPrint(lb, "{s} {s} · {s}", .{ role, &fp, trust.label() }) catch null;
            }
        }
    };

    if (sc.session.*) |host| report.one(sc.known, host, "host", &count, &first_line, &line_buf);
    if (sc.hub.*) |*h| {
        for (h.clients.items) |p| report.one(sc.known, p.sess, "guest", &count, &first_line, &line_buf);
    }

    if (count == 0) return ok_echo(ctx, "no peers connected");
    if (count == 1 and first_line != null) return ok_echo(ctx, first_line.?);
    var buf: [48]u8 = undefined;
    return ok_echo(ctx, std.fmt.bufPrint(&buf, "{d} peers (see log for SAS)", .{count}) catch "peers");
}

/// `grant <fingerprint> <grade>` — authorize a connected peer by identity
/// (host side). The grade takes effect immediately for a live peer and is
/// remembered for future reconnects of that fingerprint.
pub fn grantHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.TypeMismatch;
    const fp = parseFingerprint(args[0].string) orelse
        return ok_echo(ctx, "grant: expected a fingerprint like k7q2-9fh3-...");
    const grade = core.session.Access.parse(args[1].string) orelse
        return ok_echo(ctx, "grant: grade must be view|edit|own");
    const h = &(sc.hub.* orelse return ok_echo(ctx, "grant: not hosting (start listen first)"));
    h.setPeerAccess(fp, grade) catch |err| {
        var buf: [64]u8 = undefined;
        return ok_echo(ctx, std.fmt.bufPrint(&buf, "grant failed: {t}", .{err}) catch "grant failed");
    };
    var buf: [64]u8 = undefined;
    return ok_echo(ctx, std.fmt.bufPrint(&buf, "granted {s} to {s}", .{ grade.label(), &fp }) catch "granted");
}

/// `cancel` (C-g) — records the intent; the frame loop drops queued
/// connect/listen requests and detaches an in-flight connect.
pub fn cancelHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    sc.cancel_requested = true;
    return ok_echo(ctx, "canceled");
}

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

pub fn identityHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    const id: *core.identity.Identity = @ptrCast(@alignCast(data.?));
    var buf: [48]u8 = undefined;
    return ok_echo(ctx, std.fmt.bufPrint(&buf, "identity {s}", .{&id.fingerprint()}) catch "identity");
}

/// Parse a 24-char fingerprint argument (five base32 groups) into bytes.
fn parseFingerprint(s: []const u8) ?[24]u8 {
    if (s.len != 24) return null;
    var fp: [24]u8 = undefined;
    @memcpy(&fp, s);
    return fp;
}

pub fn verifyPeerHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const kp: *core.known_peers.KnownPeers = @ptrCast(@alignCast(data.?));
    if (args.len != 1 or args[0] != .string) return error.TypeMismatch;
    const fp = parseFingerprint(args[0].string) orelse
        return ok_echo(ctx, "verify-peer: expected a fingerprint like k7q2-9fh3-...");
    kp.verify(fp) catch |err| {
        var buf: [64]u8 = undefined;
        return ok_echo(ctx, std.fmt.bufPrint(&buf, "verify-peer failed: {t}", .{err}) catch "verify-peer failed");
    };
    var buf: [48]u8 = undefined;
    return ok_echo(ctx, std.fmt.bufPrint(&buf, "verified {s}", .{&fp}) catch "verified");
}

pub fn forgetPeerHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const kp: *core.known_peers.KnownPeers = @ptrCast(@alignCast(data.?));
    if (args.len != 1 or args[0] != .string) return error.TypeMismatch;
    const fp = parseFingerprint(args[0].string) orelse
        return ok_echo(ctx, "forget-peer: expected a fingerprint like k7q2-9fh3-...");
    kp.forget(fp) catch |err| {
        var buf: [64]u8 = undefined;
        return ok_echo(ctx, std.fmt.bufPrint(&buf, "forget-peer failed: {t}", .{err}) catch "forget-peer failed");
    };
    var buf: [48]u8 = undefined;
    return ok_echo(ctx, std.fmt.bufPrint(&buf, "forgot {s}", .{&fp}) catch "forgot");
}

/// Bind every collaboration command against the shared state. Called after
/// plugins/config load (so a plugin binding the same name still wins,
/// last-wins) — preserving the exact order these were registered inline.
/// `sc` and `known` are borrowed as command `data` and must outlive the run.
pub fn registerCommands(gpa: std.mem.Allocator, commands: *core.command.Commands, sc: *ShareCtx, known: *core.known_peers.KnownPeers) !void {
    _ = try commands.bind(gpa, "connect", .{
        .name = "connect",
        .summary = "Connect to a host at runtime; its document opens as a buffer.",
        .args = &.{.{ .name = "hostport", .type = .string }},
        .handler = connectHandler,
        .data = sc,
    });
    _ = try commands.bind(gpa, "disconnect", .{
        .name = "disconnect",
        .summary = "Drop the connection; shared buffers stay as local copies.",
        .args = &.{},
        .handler = disconnectHandler,
        .data = sc,
    });
    _ = try commands.bind(gpa, "realize-all", .{
        .name = "realize-all",
        .summary = "Fetch the whole partial checkout.",
        .args = &.{},
        .handler = realizeAllHandler,
        .data = sc,
    });
    _ = try commands.bind(gpa, "share", .{
        .name = "share",
        .summary = "Share the active buffer over the connection.",
        .args = &.{},
        .handler = shareHandler,
        .data = sc,
    });
    _ = try commands.bind(gpa, "open-shared", .{
        .name = "open-shared",
        .summary = "Pick one of the peer's shared buffers and open it.",
        .args = &.{},
        .handler = openSharedHandler,
        .data = sc,
    });
    _ = try commands.bind(gpa, "listen", .{
        .name = "listen",
        .summary = "Host on a port at an access grade (view|edit|own); peers connect and share buffers.",
        .args = &.{ .{ .name = "port", .type = .string }, .{ .name = "access", .type = .string } },
        .handler = listenHandler,
        .data = sc,
    });
    _ = try commands.bind(gpa, "stop-listening", .{
        .name = "stop-listening",
        .summary = "Stop accepting new peers (connected peers stay).",
        .args = &.{},
        .handler = stopListeningHandler,
        .data = sc,
    });
    _ = try commands.bind(gpa, "verify-peer", .{
        .name = "verify-peer",
        .summary = "Mark a peer fingerprint verified (after comparing its SAS out of band).",
        .args = &.{.{ .name = "fingerprint", .type = .string }},
        .handler = verifyPeerHandler,
        .data = known,
    });
    _ = try commands.bind(gpa, "forget-peer", .{
        .name = "forget-peer",
        .summary = "Revoke trust in a peer fingerprint (removes it from known_peers).",
        .args = &.{.{ .name = "fingerprint", .type = .string }},
        .handler = forgetPeerHandler,
        .data = known,
    });
    _ = try commands.bind(gpa, "peers", .{
        .name = "peers",
        .summary = "List connected peers with fingerprint, SAS words, and trust.",
        .args = &.{},
        .handler = peersHandler,
        .data = sc,
    });
    _ = try commands.bind(gpa, "cancel", .{
        .name = "cancel",
        .summary = "Abort a pending/in-flight connect and drop queued host intents.",
        .args = &.{},
        .handler = cancelHandler,
        .data = sc,
    });
    _ = try commands.bind(gpa, "grant", .{
        .name = "grant",
        .summary = "Set a connected peer's grade by fingerprint (view|edit|own).",
        .args = &.{ .{ .name = "fingerprint", .type = .string }, .{ .name = "grade", .type = .string } },
        .handler = grantHandler,
        .data = sc,
    });
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
fn wireHubShare(sc: *ShareCtx, peer: *core.hub.Peer, col: *core.session.Collab, doc: *core.Document) !void {
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

/// `listen <port>` — start hosting at runtime (records the intent; the
/// frame loop starts the hub outside the hot section).
pub fn listenHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.TypeMismatch;
    if (sc.hub.* != null) return .{ .string = "already listening (stop-listening first)" };
    const port = std.fmt.parseInt(u16, args[0].string, 10) catch return .{ .string = "bad port" };
    const access = core.session.Access.parse(args[1].string) orelse
        return .{ .string = "access must be view|edit|own" };
    sc.pending_listen = port;
    sc.pending_access = access;
    var buf: [48]u8 = undefined;
    return ok_echo(ctx, std.fmt.bufPrint(&buf, "listening ({s} access)…", .{access.label()}) catch "listening…");
}

/// `stop-listening` — stop accepting new peers; connected peers stay.
pub fn stopListeningHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    if (sc.hub.* == null) return .{ .string = "not listening" };
    sc.stop_listen_requested = true;
    return ok_echo(ctx, "no longer accepting peers");
}

/// `connect host:port` — join a host at runtime (the remote primary
/// opens as a new buffer). No auto-reconnect for runtime connections.
pub fn connectHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 1 or args[0] != .string) return error.TypeMismatch;
    if (sc.conn.* != null) return .{ .string = "already connected (disconnect first)" };
    if (sc.pending_connect) |old| ctx.gpa.free(old);
    sc.pending_connect = try ctx.gpa.dupe(u8, args[0].string);
    return ok_echo(ctx, "connecting…");
}

/// `disconnect` — drop the connection; shared buffers stay as local
/// copies.
pub fn disconnectHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    if (sc.conn.* == null) return .{ .string = "not connected" };
    sc.disconnect_requested = true;
    return ok_echo(ctx, "disconnecting…");
}

/// `realize-all` — fetch the whole partial checkout.
pub fn realizeAllHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    const p = if (sc.partial.*) |*p| p else return .{ .string = "not a partial checkout" };
    p.fetch_all = true;
    return ok_echo(ctx, "fetching the whole document…");
}

/// `share` — announce the active buffer to the peer(s): over the
/// outbound connection AND to every hub peer, remembering it for late
/// joiners. One history root; the peer's frontier exchange bootstraps
/// content. The hub's primary buffer is already served, so it is skipped.
pub fn shareHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    if (sc.conn.* == null and sc.hub.* == null) return .{ .string = "not connected" };
    const buf = ctx.buffer();
    const doc = &buf.editor.doc;
    var did = false;

    if (sc.conn.*) |*c| {
        var already = false;
        for (c.collabs.items) |col| if (col.tag == buf.id) {
            already = true;
            break;
        };
        if (!already) {
            const col = try c.share(doc, buf.name, buf.id);
            col.presence_layer = try sc.caps.layers.claim(ctx.gpa, doc, "presence", .replicated, "collab");
            col.export_diag_layer = sc.caps.layers.find(doc, "diagnostics");
            did = true;
        }
    }

    if (sc.hub.*) |*h| {
        const is_primary = if (sc.primary_doc) |pd| pd == doc else false;
        var recorded = false;
        for (sc.shared.items) |s| if (s.tag == buf.id) {
            recorded = true;
            break;
        };
        if (!is_primary and !recorded) {
            const name_owned = try sc.gpa.dupe(u8, buf.name);
            errdefer sc.gpa.free(name_owned);
            try sc.shared.append(sc.gpa, .{ .doc = doc, .name = name_owned, .tag = buf.id });
            _ = sc.caps.layers.claim(ctx.gpa, doc, "presence", .replicated, "collab") catch {};
            for (h.clients.items) |peer| {
                var has = false;
                for (peer.conn.collabs.items) |col| if (col.tag == buf.id) {
                    has = true;
                    break;
                };
                if (has) continue;
                const scol = peer.conn.share(doc, buf.name, buf.id) catch continue;
                wireHubShare(sc, peer, scol, doc) catch continue;
            }
            did = true;
        }
    }

    if (!did) return .{ .string = "already shared" };
    std.log.info("shared buffer {s}", .{buf.name});
    return .nil;
}

/// One openable offer across all connections: the owning Conn, the hub
/// peer it belongs to (null for the outbound connection), the Conn-local
/// offer index, and its display name (borrowed).
const OfferRef = struct {
    conn: *core.session.Conn,
    peer: ?*core.hub.Peer,
    index: usize,
    name: []const u8,
};

fn collectOffers(sc: *ShareCtx, gpa: std.mem.Allocator, out: *std.ArrayList(OfferRef)) !void {
    if (sc.conn.*) |*c| {
        for (c.offers.items, 0..) |o, i| {
            if (!o.opened) try out.append(gpa, .{ .conn = c, .peer = null, .index = i, .name = o.name });
        }
    }
    if (sc.hub.*) |*h| {
        for (h.clients.items) |peer| {
            for (peer.conn.offers.items, 0..) |o, i| {
                if (!o.opened) try out.append(gpa, .{ .conn = &peer.conn, .peer = peer, .index = i, .name = o.name });
            }
        }
    }
}

/// `open-shared` — pick over every peer's unopened announcements
/// (outbound host + all hub peers); accept opens it into a fresh buffer.
pub fn openSharedHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    var refs: std.ArrayList(OfferRef) = .empty;
    defer refs.deinit(ctx.gpa);
    try collectOffers(sc, ctx.gpa, &refs);
    if (refs.items.len == 0) return .{ .string = "no shared buffers offered" };
    var texts: std.ArrayList([]u8) = .empty;
    defer {
        for (texts.items) |it| ctx.gpa.free(it);
        texts.deinit(ctx.gpa);
    }
    var entries: std.ArrayList(core.pick.Entry) = .empty;
    defer entries.deinit(ctx.gpa);
    for (refs.items, 0..) |r, i| {
        const text = try std.fmt.allocPrint(ctx.gpa, "{d}: @{s}", .{ i, r.name });
        try texts.append(ctx.gpa, text);
        try entries.append(ctx.gpa, .{ .text = text, .doc = "shared by a peer — open to collaborate" });
    }
    try ctx.pick.open(ctx, "shared", entries.items, .{ .handler = openSharedAccept, .data = sc });
    return .nil;
}

fn openSharedAccept(ctx: *core.command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    const colon = std.mem.indexOfScalar(u8, choice, ':') orelse return;
    const list_idx = std.fmt.parseInt(usize, choice[0..colon], 10) catch return;
    var refs: std.ArrayList(OfferRef) = .empty;
    defer refs.deinit(ctx.gpa);
    collectOffers(sc, ctx.gpa, &refs) catch return;
    if (list_idx >= refs.items.len) return;
    const ref = refs.items[list_idx];
    if (ref.index >= ref.conn.offers.items.len or ref.conn.offers.items[ref.index].opened) return;

    const display = try std.fmt.allocPrint(ctx.gpa, "@{s}", .{ref.name});
    defer ctx.gpa.free(display);
    const id = try ctx.buffers.create(ctx.gpa, display);
    const buf = ctx.buffers.get(id).?;
    const doc = &buf.editor.doc;
    const col = try ref.conn.openOffer(ref.index, doc, id);
    if (ref.peer) |peer| {
        // A hub peer shared a buffer to us: participate + relay it.
        try wireHubShare(sc, peer, col, doc);
        _ = sc.caps.layers.claim(ctx.gpa, doc, "presence", .replicated, "collab") catch {};
    } else {
        // Offered by the host we connected out to.
        col.presence_layer = try sc.caps.layers.claim(ctx.gpa, doc, "presence", .replicated, "collab");
        col.import_diag_layer = try sc.caps.layers.claim(ctx.gpa, doc, "diagnostics", .host, "remote-host");
    }
    try ctx.buffers.switchTo(ctx.gpa, id, ctx.keymap);
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

/// Runtime connect: fresh buffer for the remote primary, client
/// session + Conn bound to it.
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
