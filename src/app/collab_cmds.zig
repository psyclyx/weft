//! Collaboration command handlers + their registration. These record intents
//! on the shared `collab.ShareCtx` (the frame loop applies them) or act on the
//! TOFU trust store; the state, wiring, and frame-loop appliers live in
//! `collab.zig`. Split out so neither file exceeds a single concern's size.

const std = @import("std");
const core = @import("../core/core.zig");
const handler = @import("handler.zig");
const ok_echo = handler.ok_echo;
const collab = @import("collab.zig");
const ShareCtx = collab.ShareCtx;
const wireHubShare = collab.wireHubShare;

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

// ── Listen / connect / share commands ───────────────────────────────

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

/// `peer-files` opens the peer's published shared-root target through ordinary
/// target resolution. The command does not select dired or inspect a
/// filesystem fact; whichever plugin claims the target owns the experience.
pub fn peerFilesHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    const target = sc.remote_fs_target orelse return ok_echo(ctx, "peer has no shared filesystem");
    const semantic = ctx.semantic orelse return ok_echo(ctx, "semantic targets are unavailable");
    return switch (try core.target_open.openLocated(semantic, ctx.head, ctx.gpa, target, null)) {
        .opened => .nil,
        .no_handler => ok_echo(ctx, "no plugin handles the peer filesystem target"),
        .ambiguous => ok_echo(ctx, "multiple plugins claim the peer filesystem target"),
    };
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

/// One openable offer across all connections. `base` is the offer's stable
/// identity on its owning connection; the array index is only a snapshot used
/// while building the display list and must never be used to resolve an
/// acceptance later.
const OfferRef = struct {
    conn: *core.session.Conn,
    incarnation: [core.secure.pub_len]u8,
    fingerprint: [24]u8,
    base: u64,
    name: []const u8,
};

/// The target table belongs to one pick session. It owns the names used to
/// label the candidates, while `(conn, incarnation, fingerprint, base)` is
/// the source-defined target identity. The connection pointer is only a token until
/// `resolveOffer` proves it is still a live outbound/hub connection.
const OpenSharedState = struct {
    sc: *ShareCtx,
    targets: std.ArrayList(Target) = .empty,

    const Target = struct {
        /// Pointer is opaque until found in the current live set. Incarnation
        /// closes reconnect/address ABA; fingerprint proves the peer identity.
        conn: *core.session.Conn,
        incarnation: [core.secure.pub_len]u8,
        fingerprint: [24]u8,
        base: u64,
        name: []u8,
    };

    fn deinit(self: *OpenSharedState, gpa: std.mem.Allocator) void {
        for (self.targets.items) |target| gpa.free(target.name);
        self.targets.deinit(gpa);
    }
};

fn openSharedCleanup(data: ?*anyopaque, gpa: std.mem.Allocator) void {
    const state: *OpenSharedState = @ptrCast(@alignCast(data.?));
    state.deinit(gpa);
    gpa.destroy(state);
}

const LiveOffer = struct {
    conn: *core.session.Conn,
    peer: ?*core.hub.Peer,
    index: usize,
};

fn resolveOfferOnConn(
    target: OpenSharedState.Target,
    conn: *core.session.Conn,
    incarnation: [core.secure.pub_len]u8,
    fingerprint: [24]u8,
    peer: ?*core.hub.Peer,
) ?LiveOffer {
    if (conn != target.conn or
        !std.mem.eql(u8, &incarnation, &target.incarnation) or
        !std.mem.eql(u8, &fingerprint, &target.fingerprint)) return null;
    for (conn.offers.items, 0..) |offer, i| {
        if (offer.base == target.base and !offer.opened)
            return .{ .conn = conn, .peer = peer, .index = i };
    }
    return null;
}

/// Re-resolve a snapshotted target without consulting the current display
/// ordering. Pointer comparison is safe before dereference: a disconnected
/// outbound Conn or removed hub Peer simply fails the identity check.
fn resolveOffer(sc: *ShareCtx, target: OpenSharedState.Target) ?LiveOffer {
    if (sc.conn.*) |*conn| {
        if (conn == target.conn) {
            const fingerprint = conn.session.peerFingerprint() orelse return null;
            return resolveOfferOnConn(target, conn, conn.session.incarnation(), fingerprint, null);
        }
    }
    if (sc.hub.*) |*hub| {
        for (hub.clients.items) |peer| {
            if (&peer.conn != target.conn) continue;
            const fingerprint = peer.sess.peerFingerprint() orelse return null;
            return resolveOfferOnConn(target, &peer.conn, peer.sess.incarnation(), fingerprint, peer);
        }
    }
    return null;
}

fn collectOffers(sc: *ShareCtx, gpa: std.mem.Allocator, out: *std.ArrayList(OfferRef)) !void {
    if (sc.conn.*) |*c| {
        const fingerprint = c.session.peerFingerprint();
        for (c.offers.items) |o| {
            if (!o.opened and fingerprint != null) try out.append(gpa, .{
                .conn = c,
                .incarnation = c.session.incarnation(),
                .fingerprint = fingerprint.?,
                .base = o.base,
                .name = o.name,
            });
        }
    }
    if (sc.hub.*) |*h| {
        for (h.clients.items) |peer| {
            const fingerprint = peer.sess.peerFingerprint();
            for (peer.conn.offers.items) |o| {
                if (!o.opened and fingerprint != null) try out.append(gpa, .{
                    .conn = &peer.conn,
                    .incarnation = peer.sess.incarnation(),
                    .fingerprint = fingerprint.?,
                    .base = o.base,
                    .name = o.name,
                });
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
    const state = try ctx.gpa.create(OpenSharedState);
    state.* = .{ .sc = sc };
    errdefer openSharedCleanup(state, ctx.gpa);
    for (refs.items, 0..) |r, i| {
        const text = try std.fmt.allocPrint(ctx.gpa, "{d}: @{s}", .{ i, r.name });
        try texts.append(ctx.gpa, text);
        try entries.append(ctx.gpa, .{ .text = text, .doc = "shared by a peer — open to collaborate" });
        const name = try ctx.gpa.dupe(u8, r.name);
        state.targets.append(ctx.gpa, .{
            .conn = r.conn,
            .incarnation = r.incarnation,
            .fingerprint = r.fingerprint,
            .base = r.base,
            .name = name,
        }) catch |err| {
            ctx.gpa.free(name);
            return err;
        };
    }
    try ctx.head.pick.open(ctx, "shared", entries.items, .{
        .handler = openSharedAccept,
        .cleanup = openSharedCleanup,
        .data = state,
    });
    return .nil;
}

fn openSharedAccept(ctx: *core.command.Context, data: ?*anyopaque, outcome: core.pick.Outcome) anyerror!void {
    const state: *OpenSharedState = @ptrCast(@alignCast(data.?));
    const candidate = switch (outcome) {
        .cancelled => return,
        .candidate => |candidate| candidate,
        .input => return,
    };
    if (candidate.index >= state.targets.items.len) return;
    const target = state.targets.items[candidate.index];
    const ref = resolveOffer(state.sc, target) orelse return;

    const display = try std.fmt.allocPrint(ctx.gpa, "@{s}", .{target.name});
    defer ctx.gpa.free(display);
    const id = try ctx.buffers.create(ctx.gpa, display);
    const buf = ctx.buffers.get(id).?;
    const doc = &buf.editor.doc;
    const col = try ref.conn.openOffer(ref.index, doc, id);
    if (ref.peer) |peer| {
        // A hub peer shared a buffer to us: participate + relay it.
        try wireHubShare(state.sc, peer, col, doc);
        _ = state.sc.caps.layers.claim(ctx.gpa, doc, "presence", .replicated, "collab") catch {};
    } else {
        // Offered by the host we connected out to.
        col.presence_layer = try state.sc.caps.layers.claim(ctx.gpa, doc, "presence", .replicated, "collab");
        col.import_diag_layer = try state.sc.caps.layers.claim(ctx.gpa, doc, "diagnostics", .host, "remote-host");
    }
    try ctx.buffers.switchTo(ctx.gpa, id, ctx.head, ctx.keymap);
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
    _ = try commands.bind(gpa, "peer-files", .{
        .name = "peer-files",
        .summary = "Open the connected peer's shared filesystem target.",
        .args = &.{},
        .handler = peerFilesHandler,
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

test "open-shared resolves the snapshotted offer base after display reordering" {
    const gpa = std.testing.allocator;
    var conn_slot: ?core.session.Conn = .{
        .gpa = gpa,
        .session = undefined,
        .name = &.{},
        .role = .client,
        .next_base = 20,
    };
    const conn = &conn_slot.?;
    defer {
        for (conn.offers.items) |offer| gpa.free(offer.name);
        conn.offers.deinit(gpa);
    }
    try conn.offers.append(gpa, .{ .base = 16, .name = try gpa.dupe(u8, "first") });
    try conn.offers.append(gpa, .{ .base = 24, .name = try gpa.dupe(u8, "second") });

    const fingerprint: [24]u8 = @splat(7);
    const incarnation: [core.secure.pub_len]u8 = @splat(11);
    const target: OpenSharedState.Target = .{
        .conn = conn,
        .incarnation = incarnation,
        .fingerprint = fingerprint,
        .base = 24,
        .name = &.{},
    };

    // A new offer can arrive before acceptance, changing the display index.
    // The target must still resolve by its connection identity + base.
    try conn.offers.insert(gpa, 0, .{ .base = 8, .name = try gpa.dupe(u8, "new") });
    const resolved = resolveOfferOnConn(target, conn, incarnation, fingerprint, null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), resolved.index);
    try std.testing.expectEqual(@as(u64, 24), resolved.conn.offers.items[resolved.index].base);

    // Once that same offer is consumed, acceptance degrades to a no-op rather
    // than opening whichever row now occupies its old slot.
    conn.offers.items[resolved.index].opened = true;
    try std.testing.expect(resolveOfferOnConn(target, conn, incarnation, fingerprint, null) == null);

    // A vanished offer follows the same safe path.
    const removed = conn.offers.orderedRemove(resolved.index);
    gpa.free(removed.name);
    try std.testing.expect(resolveOfferOnConn(target, conn, incarnation, fingerprint, null) == null);

    // Pointer reuse alone is not identity: a different authenticated peer at
    // the same address cannot inherit the old pick target.
    var other_fingerprint = fingerprint;
    other_fingerprint[0] +%= 1;
    try std.testing.expect(resolveOfferOnConn(target, conn, incarnation, other_fingerprint, null) == null);

    // The same authenticated peer can reconnect and restart its base counter.
    // A new lifetime at the same allocator address is still not this target.
    try conn.offers.append(gpa, .{ .base = target.base, .name = try gpa.dupe(u8, "reconnected") });
    var other_incarnation = incarnation;
    other_incarnation[0] +%= 1;
    try std.testing.expect(resolveOfferOnConn(target, conn, other_incarnation, fingerprint, null) == null);
}
