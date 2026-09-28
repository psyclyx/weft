//! Collaboration command handlers + their registration. These record intents
//! on the shared `collab.ShareCtx` (the frame loop applies them) or act on the
//! TOFU trust store; the state, wiring, and frame-loop appliers live in
//! `collab.zig`. Split out so neither file exceeds a single concern's size.

const std = @import("std");
const core = @import("weft_core");
const handler = @import("handler.zig");
const ok_echo = handler.ok_echo;
const collab = @import("collab.zig");
const ShareCtx = collab.ShareCtx;
const wireHubShare = collab.wireHubShare;
const presets = @import("collab_presets.zig");
const PeerFile = @import("peer_file.zig");

// ── Peer trust + identity ───────────────────────────────────────────

/// `peers` — echo/log every connected peer's fingerprint, four-word SAS,
/// and trust grade, so a user can compare the SAS out of band and then
/// `collab.verify-peer <fingerprint>`. The full detail goes to the log (many
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
        return ok_echo(ctx, "collab.verify-peer: expected a fingerprint like k7q2-9fh3-...");
    kp.verify(fp) catch |err| {
        var buf: [64]u8 = undefined;
        return ok_echo(ctx, std.fmt.bufPrint(&buf, "collab.verify-peer failed: {t}", .{err}) catch "collab.verify-peer failed");
    };
    var buf: [48]u8 = undefined;
    return ok_echo(ctx, std.fmt.bufPrint(&buf, "verified {s}", .{&fp}) catch "verified");
}

pub fn forgetPeerHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const kp: *core.known_peers.KnownPeers = @ptrCast(@alignCast(data.?));
    if (args.len != 1 or args[0] != .string) return error.TypeMismatch;
    const fp = parseFingerprint(args[0].string) orelse
        return ok_echo(ctx, "collab.forget-peer: expected a fingerprint like k7q2-9fh3-...");
    kp.forget(fp) catch |err| {
        var buf: [64]u8 = undefined;
        return ok_echo(ctx, std.fmt.bufPrint(&buf, "collab.forget-peer failed: {t}", .{err}) catch "collab.forget-peer failed");
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

/// `collab.share-presence <on|off>` — select cursor sharing, separately from
/// sharing a document. The choice applies to every already-shared document
/// and to later ones; `off` retracts the caret peers are already rendering.
pub fn sharePresenceHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 1 or args[0] != .string) return error.TypeMismatch;
    const on = if (std.mem.eql(u8, args[0].string, "on"))
        true
    else if (std.mem.eql(u8, args[0].string, "off"))
        false
    else
        return .{ .string = "share-presence must be on|off" };

    sc.publish_presence = on;
    if (sc.conn.*) |*c| for (c.collabs.items) |col| try col.setPublishPresence(on);
    if (sc.hub.*) |*h| for (h.clients.items) |peer| {
        for (peer.conn.collabs.items) |col| try col.setPublishPresence(on);
    };
    return ok_echo(ctx, if (on) "sharing your cursor" else "cursor hidden — peers no longer see it");
}

/// `collab.share-fs <selection>` — select which export surfaces of the shared root
/// peers hold: `hierarchy`, `bytes`, `write` (comma-separated), or a preset
/// (`none`/`read`/`rw`). Applies to every connected peer at once and to
/// later ones; narrowing takes effect on their next request.
pub fn shareFsHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 1 or args[0] != .string) return error.TypeMismatch;
    const grant = core.peer_fs.parseGrant(args[0].string) orelse
        return .{ .string = "share-fs takes hierarchy|bytes|write (comma-separated) or none|read|rw" };
    if (sc.peer_fs_root == null and grant.any()) return .{ .string = "no shared root (start with --share-root)" };

    sc.fs_grant = grant;
    if (sc.hub.*) |*h| for (h.clients.items) |peer| {
        for (peer.conn.collabs.items) |col| col.fs_grant = grant;
    };
    var buf: [96]u8 = undefined;
    return ok_echo(ctx, std.fmt.bufPrint(&buf, "peers may {s}", .{fsGrantNote(grant)}) catch "shared filesystem updated");
}

/// What a peer can do with the shared root, in the words the person picking
/// it used.
pub fn fsGrantNote(grant: core.peer_fs.Grant) []const u8 {
    const surfaces: u3 = @as(u3, @intFromBool(grant.hierarchy)) |
        @as(u3, @intFromBool(grant.bytes)) << 1 |
        @as(u3, @intFromBool(grant.mutate)) << 2;
    return switch (surfaces) {
        0b000 => "not reach the shared filesystem",
        0b001 => "list the shared files",
        0b010 => "read shared file contents",
        0b011 => "list and read the shared files",
        0b100 => "write shared files",
        0b101 => "list and write the shared files",
        0b110 => "read and write shared file contents",
        0b111 => "list, read, and write the shared files",
    };
}

/// `collab.stop-listening` — stop accepting new peers; connected peers stay.
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

/// `collab.realize-all` — fetch the whole partial checkout.
pub fn realizeAllHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    const p = if (sc.partial.*) |*p| p else return .{ .string = "not a partial checkout" };
    p.fetch_all = true;
    return ok_echo(ctx, "fetching the whole document…");
}

/// `collab.peer-files` opens the peer's shared tree — which is to say it runs `open`
/// on the tree's designation, `weft://<fingerprint>/dir/`, and nothing else.
/// There is one path to a peer's directory, whether a person asked for the
/// root by this name or for `weft://<peer>/dir/src` by designation: the one
/// `openPeer` routes, which presents it as every directory is presented.
pub fn peerFilesHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    const target = sc.remote_fs_target orelse return ok_echo(ctx, "peer has no shared filesystem");
    const router = ctx.filesystems orelse return ok_echo(ctx, "filesystems are unavailable");
    const named = router.designationOf(target.target, target.revision) orelse
        return ok_echo(ctx, "the peer's shared tree has no designation yet (no handshake)");
    const text = try ctx.gpa.dupe(u8, named);
    defer ctx.gpa.free(text);
    return core.command.run(ctx.commands, ctx, "file.open", &.{.{ .string = text }});
}

// ── Peer designations (doc/model.md §2.1) ───────────────────────────

/// `open`'s route for a peer authority (`buffers_cmds.PeerOpener`): the
/// peer's shared tree and the directories below it (`dir`), and a document it
/// shares (`doc`, by its minted id — stable across reconnects, where the wire
/// base is not), and a file in its tree (`file`, backed by the file itself
/// through the peer's filesystem surfaces — `openPeerFile`).
pub fn openPeer(raw: *anyopaque, ctx: *core.command.Context, d: core.designation.Designation) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(raw));
    const fingerprint = switch (d.authority) {
        .peer => |fp| fp,
        else => return .{ .string = core.designation.refuse_unreachable },
    };
    return switch (d.kind) {
        .directory => openPeerDirectory(sc, ctx, fingerprint, d.ref),
        .doc => openPeerDocument(sc, ctx, fingerprint, d.docId() orelse return .{ .string = core.designation.refuse_doc_gone }),
        .file => openPeerFile(sc, ctx, fingerprint, d),
        else => .{ .string = core.designation.refuse_unreachable },
    };
}

/// The registries a peer's tree is published in, or null (with the refusal
/// in `why`) in an embedding without them.
fn registries(ctx: *core.command.Context, why: *[]const u8) ?struct { *core.semantic.Services, *@import("weft_fs_runtime").Router } {
    const services = ctx.semantic orelse {
        why.* = core.designation.refuse_unreachable;
        return null;
    };
    const router = ctx.filesystems orelse {
        why.* = core.designation.refuse_unreachable;
        return null;
    };
    return .{ services, router };
}

fn peerDirectory(sc: *ShareCtx, ctx: *core.command.Context, fingerprint: []const u8, path: []const u8, why: *[]const u8) !?@import("weft_semantic").target.Located {
    const services, const router = registries(ctx, why) orelse return null;
    return PeerFile.directory(sc, services, router, fingerprint, path, why);
}

/// A peer's FILE, as an entry backed by the file itself (`PeerFile`): read
/// through the peer's tree, named by its peer designation, in the peer's
/// place — and saved back through the peer's write surface by the guarded
/// test-and-set every remote tier shares, merging what the peer's disk did
/// meanwhile. Where the peer granted no write surface the entry is
/// read-only, and a refused keystroke says exactly that.
fn openPeerFile(sc: *ShareCtx, ctx: *core.command.Context, fingerprint: []const u8, d: core.designation.Designation) anyerror!core.command.Value {
    var named: [core.designation.max_len]u8 = undefined;
    const text = try d.bare().render(&named);
    if (core.designation.findText(ctx.buffers, text)) |live| {
        try ctx.buffers.switchTo(ctx.gpa, live.id, ctx.head, ctx.keymap);
        return .{ .integer = @intCast(live.id) };
    }
    const leaf = std.fs.path.basenamePosix(d.ref);
    if (leaf.len == 0) return .{ .string = "open: that names no file" };
    var why: []const u8 = "";
    const services, const router = registries(ctx, &why) orelse return .{ .string = why };
    // The directory first, so a missing one is refused by name.
    _ = (try PeerFile.directory(sc, services, router, fingerprint, std.fs.path.dirnamePosix(d.ref) orelse "/", &why)) orelse return .{ .string = why };
    const remote = try PeerFile.create(ctx.gpa, sc, services, router, fingerprint, d.ref);
    const writable = PeerFile.of(remote).?.writable();
    const id = try ctx.buffers.create(ctx.gpa, leaf);
    errdefer ctx.buffers.close(ctx.gpa, id, ctx.head, ctx.keymap) catch {};
    const buf = ctx.buffers.get(id).?;
    buf.textEditor().?.openRemote(ctx.gpa, remote) catch |err| switch (err) {
        error.Failed => return .{ .string = "open: the peer has no such file" },
        error.NotPermitted => return .{ .string = "open: the peer shares this tree without its bytes" },
        else => |e| return e,
    };
    if (!writable) buf.read_only = PeerFile.refuse_no_write;
    try buf.setDesignation(ctx.gpa, text);
    if (try sc.remotePlace(ctx)) |p| ctx.buffers.setPlace(id, p);
    try ctx.buffers.switchTo(ctx.gpa, id, ctx.head, ctx.keymap);
    if (buf.read_only) |reason| _ = try ok_echo(ctx, reason);
    return .{ .integer = @intCast(id) };
}

/// The directory `path` in the tree the peer `fingerprint` shares with us,
/// presented as a listing. Reached from the tree's root by names, each one
/// looked up in the provider's own listing of its parent
/// (`publishChildByName`), so what opens is what the peer really has there.
fn openPeerDirectory(sc: *ShareCtx, ctx: *core.command.Context, fingerprint: []const u8, path: []const u8) anyerror!core.command.Value {
    var why: []const u8 = "";
    const at = (try peerDirectory(sc, ctx, fingerprint, path, &why)) orelse return .{ .string = why };
    try @import("session.zig").presentDirectory(ctx, at);
    // The listing is IN the peer's tree, wherever it was opened from.
    if (try sc.remotePlace(ctx)) |p| ctx.buffers.setPlace(ctx.buffers.active_id, p);
    return .nil;
}

/// The document with minted id `id` that peer `fingerprint` offers — opened
/// into a fresh replica, or focused if an entry already holds it.
fn openPeerDocument(sc: *ShareCtx, ctx: *core.command.Context, fingerprint: []const u8, id: core.Document.Id) anyerror!core.command.Value {
    if (sc.conn.*) |*conn| if (conn.session.peerFingerprint()) |fp| if (std.mem.eql(u8, &fp, fingerprint)) {
        if (conn.offerFor(id)) |index| return .{ .integer = @intCast(try openOffer(sc, ctx, .{ .conn = conn, .peer = null, .index = index }, &fp)) };
    };
    if (sc.hub.*) |*hub| for (hub.clients.items) |peer| {
        const fp = peer.sess.peerFingerprint() orelse continue;
        if (!std.mem.eql(u8, &fp, fingerprint)) continue;
        if (peer.conn.offerFor(id)) |index| return .{ .integer = @intCast(try openOffer(sc, ctx, .{ .conn = &peer.conn, .peer = peer, .index = index }, &fp)) };
    };
    return .{ .string = "open: that peer offers no such document now" };
}

/// How a peer authority reads in a title (`designation.PeerNames`): the
/// address the person connected out to, for the peer at the other end of
/// that connection. Any other peer reads as its fingerprint.
pub fn peerName(raw: *anyopaque, fingerprint: []const u8) ?[]const u8 {
    const sc: *ShareCtx = @ptrCast(@alignCast(raw));
    const label = sc.peer_label orelse return null;
    const s = sc.session.* orelse return null;
    const fp = s.peerFingerprint() orelse return null;
    return if (std.mem.eql(u8, &fp, fingerprint)) label else null;
}

/// `share [preset]` — announce the active buffer to the peer(s): over the
/// outbound connection AND to every hub peer, remembering it for late
/// joiners. One history root; the peer's frontier exchange bootstraps
/// content. The hub's primary buffer is already served, so it is skipped.
///
/// An optional preset name (doc/contextual-workspace-architecture.md §13.6:
/// "look_together" | "pair" | "review") compiles to a `collab_presets`
/// `GrantBundle`; the echo below is rendered FROM that bundle
/// (`collab_presets.echo`), never from a preset-supplied string — the text
/// approved and the authority selected are the same value. The bundle
/// selects the presence toggle and the quad's exported surfaces; the
/// project-scope, git and process toggles have no export to select yet.
pub fn shareHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len > 1) return error.ArityMismatch;
    var bundle: ?presets.GrantBundle = null;
    if (args.len == 1) {
        if (args[0] != .string) return error.TypeMismatch;
        bundle = presets.find(args[0].string) orelse
            return ok_echo(ctx, "share: preset must be look_together|pair|review");
    }
    if (sc.conn.* == null and sc.hub.* == null) return .{ .string = "not connected" };
    const buf = ctx.buffer();
    const doc = &(buf.textEditor() orelse return .{ .string = "no text to share" }).doc;
    // The toggles the preview shows are the ones the quad publishes: a
    // bundle without code intelligence must not export diagnostics anyway.
    if (bundle) |b| {
        sc.publish_presence = b.has(.presence);
        sc.export_diagnostics = b.has(.code_intel);
    }
    var did = false;

    if (sc.conn.*) |*c| {
        var already = false;
        for (c.collabs.items) |col| if (col.tag == buf.id) {
            already = true;
            break;
        };
        if (!already) {
            const col = try c.shareExports(doc, buf.name, buf.id, sc.exportSpec());
            col.presence_layer = try sc.caps.layers.claim(ctx.gpa, doc, "presence", .replicated, "collab");
            col.export_diag_layer = if (sc.export_diagnostics) sc.caps.layers.find(doc, "diagnostics") else null;
            col.publish_presence = sc.publish_presence;
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
                const scol = peer.conn.shareExports(doc, buf.name, buf.id, sc.exportSpec()) catch continue;
                wireHubShare(sc, peer, scol, doc) catch continue;
            }
            did = true;
        }
    }

    if (!did) return .{ .string = "already shared" };
    std.log.info("shared buffer {s}", .{buf.name});
    var echo_buf: [256]u8 = undefined;
    if (bundle) |b| return ok_echo(ctx, presets.echo(&echo_buf, buf.name, b));
    return ok_echo(ctx, std.fmt.bufPrint(&echo_buf, "shared {s} ({s})", .{
        buf.name,
        collab.presenceNote(sc.publish_presence),
    }) catch "shared");
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
        if (offer.base == target.base and !conn.isOpen(offer))
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
            if (!c.isOpen(o) and fingerprint != null) try out.append(gpa, .{
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
                if (!peer.conn.isOpen(o) and fingerprint != null) try out.append(gpa, .{
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

/// `collab.open-shared` — pick over every peer's unopened announcements
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
    try ctx.head.pick.openWith(ctx, "shared", entries.items, .{
        .handler = openSharedAccept,
        .cleanup = openSharedCleanup,
        .data = state,
    }, .{ .category = "shared" });
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
    _ = try openOffer(state.sc, ctx, ref, &target.fingerprint);
}

/// Open one live offer into a fresh replica entry and focus it. The entry
/// represents `weft://<fingerprint>/doc/<id>` when the offer carried the
/// document's minted id — the name that finds it again after a reconnect.
/// From a sender that predates the id it is named by its own replica,
/// which is all this side can honestly name.
fn openOffer(sc: *ShareCtx, ctx: *core.command.Context, ref: LiveOffer, fingerprint: *const [24]u8) !core.Buffers.Id {
    const offer = ref.conn.offers.items[ref.index];
    // Bound already: the entry that holds the replica is the one to show —
    // a share is bound once, never a second replica beside the first.
    if (ref.conn.findBase(offer.base)) |bound| {
        const shown = std.math.cast(core.Buffers.Id, bound.tag) orelse return error.AlreadyBound;
        if (ctx.buffers.get(shown) == null) return error.AlreadyBound;
        try ctx.buffers.switchTo(ctx.gpa, shown, ctx.head, ctx.keymap);
        return shown;
    }
    const display = try std.fmt.allocPrint(ctx.gpa, "@{s}", .{offer.name});
    defer ctx.gpa.free(display);
    const id = try ctx.buffers.create(ctx.gpa, display);
    const buf = ctx.buffers.get(id).?;
    const doc = &buf.textEditor().?.doc;
    if (offer.doc_id) |minted| {
        const spelled = minted.text();
        var named: [128]u8 = undefined;
        const d = core.designation.Designation.ofDoc(.{ .peer = fingerprint }, &spelled);
        try buf.setDesignation(ctx.gpa, try d.render(&named));
    }
    // A document the peer we share a tree with offers is in that tree's
    // place; any other peer's is in no place of ours.
    if (ref.peer == null) if (try sc.remotePlace(ctx)) |p| ctx.buffers.setPlace(id, p);
    const col = try ref.conn.openOffer(ref.index, doc, id);
    if (ref.peer) |peer| {
        // A hub peer shared a buffer to us: participate + relay it.
        try wireHubShare(sc, peer, col, doc);
        _ = sc.caps.layers.claim(ctx.gpa, doc, "presence", .replicated, "collab") catch {};
    } else {
        // Offered by the host we connected out to.
        col.presence_layer = try sc.caps.layers.claim(ctx.gpa, doc, "presence", .replicated, "collab");
        col.import_diag_layer = try sc.caps.layers.claim(ctx.gpa, doc, "diagnostics", .host, "remote-host");
        col.publish_presence = sc.publish_presence;
    }
    try ctx.buffers.switchTo(ctx.gpa, id, ctx.head, ctx.keymap);
    return id;
}

/// Bind every collaboration command against the shared state. Called after
/// plugins/config load (so a plugin binding the same name still wins,
/// last-wins) — preserving the exact order these were registered inline.
/// `sc` and `known` are borrowed as command `data` and must outlive the run.
pub fn registerCommands(gpa: std.mem.Allocator, commands: *core.command.Commands, sc: *ShareCtx, known: *core.known_peers.KnownPeers) !void {
    _ = try commands.bind(gpa, "collab.connect", .{
        .name = "collab.connect",
        .summary = "Join another person's session by its address; what they share opens as a buffer.",
        .args = &.{.{ .name = "hostport", .type = .string }},
        .handler = connectHandler,
        .data = sc,
        .meta = .{ .label = "Join Session", .icon = "link", .prompts = true },
    });
    _ = try commands.bind(gpa, "collab.disconnect", .{
        .name = "collab.disconnect",
        .summary = "Leave the shared session, keeping local copies of the buffers you had open.",
        .args = &.{},
        .handler = disconnectHandler,
        .data = sc,
        .meta = .{ .label = "Leave Session", .icon = "unplug" },
    });
    _ = try commands.bind(gpa, "collab.realize-all", .{
        .name = "collab.realize-all",
        .summary = "Download everything the other person shares, not just what you have opened.",
        .args = &.{},
        .handler = realizeAllHandler,
        .data = sc,
        .meta = .{ .label = "Download All Shared Files", .icon = "download" },
    });
    _ = try commands.bind(gpa, "collab.peer-files", .{
        .name = "collab.peer-files",
        .summary = "Browse the files the other person shares with you.",
        .args = &.{},
        .handler = peerFilesHandler,
        .data = sc,
        .meta = .{ .label = "Browse Shared Files", .icon = "folder-tree" },
    });
    _ = try commands.bind(gpa, "collab.share", .{
        .name = "collab.share",
        .summary = "Share the active buffer with the people you are connected to, optionally as a preset: look together, pair or review.",
        .args = &.{.{ .name = "preset", .type = .string, .optional = true }},
        .handler = shareHandler,
        .data = sc,
        .meta = .{ .label = "Share Buffer", .icon = "share-2" },
    });
    _ = try commands.bind(gpa, "collab.share-presence", .{
        .name = "collab.share-presence",
        .summary = "Show or hide your cursor to the people you are connected to, separately from sharing a buffer.",
        .args = &.{.{ .name = "state", .type = .string }},
        .handler = sharePresenceHandler,
        .data = sc,
        .meta = .{ .label = "Share Cursor", .icon = "eye", .prompts = true },
    });
    _ = try commands.bind(gpa, "collab.share-fs", .{
        .name = "collab.share-fs",
        .summary = "Choose what others may do with your shared files: see the tree, read contents, or write.",
        .args = &.{.{ .name = "surfaces", .type = .string }},
        .handler = shareFsHandler,
        .data = sc,
        .meta = .{ .label = "Share Files", .icon = "folder-open", .prompts = true },
    });
    _ = try commands.bind(gpa, "collab.open-shared", .{
        .name = "collab.open-shared",
        .summary = "Pick one of the buffers the other person shares and open it.",
        .args = &.{},
        .handler = openSharedHandler,
        .data = sc,
        .meta = .{ .label = "Open Shared Buffer", .icon = "file-text", .prompts = true },
    });
    _ = try commands.bind(gpa, "collab.listen", .{
        .name = "collab.listen",
        .summary = "Host a session on a port so others can join, viewing, editing or owning what you share.",
        .args = &.{ .{ .name = "port", .type = .string }, .{ .name = "access", .type = .string } },
        .handler = listenHandler,
        .data = sc,
        .meta = .{ .label = "Host Session", .icon = "users", .prompts = true },
    });
    _ = try commands.bind(gpa, "collab.stop-listening", .{
        .name = "collab.stop-listening",
        .summary = "Stop letting new people join your session; those already connected stay.",
        .args = &.{},
        .handler = stopListeningHandler,
        .data = sc,
        .meta = .{ .label = "Stop Hosting", .icon = "stop" },
    });
    _ = try commands.bind(gpa, "collab.verify-peer", .{
        .name = "collab.verify-peer",
        .summary = "Trust a person's fingerprint after you have compared their safety words with them directly.",
        .args = &.{.{ .name = "fingerprint", .type = .string }},
        .handler = verifyPeerHandler,
        .data = known,
        .meta = .{ .label = "Verify Peer", .icon = "shield-check", .prompts = true },
    });
    _ = try commands.bind(gpa, "collab.forget-peer", .{
        .name = "collab.forget-peer",
        .summary = "Stop trusting a person's fingerprint, removing it from your known peers.",
        .args = &.{.{ .name = "fingerprint", .type = .string }},
        .handler = forgetPeerHandler,
        .data = known,
        .meta = .{ .label = "Forget Peer", .prompts = true },
    });
    _ = try commands.bind(gpa, "collab.peers", .{
        .name = "collab.peers",
        .summary = "List the people connected to you, with their fingerprints, safety words and trust.",
        .args = &.{},
        .handler = peersHandler,
        .data = sc,
        .meta = .{ .label = "Show Peers", .icon = "users" },
    });
    _ = try commands.bind(gpa, "collab.cancel", .{
        .name = "collab.cancel",
        .summary = "Stop a connection attempt still in progress.",
        .args = &.{},
        .handler = cancelHandler,
        .data = sc,
        .meta = .{ .label = "Cancel Connecting" },
    });
    _ = try commands.bind(gpa, "collab.grant", .{
        .name = "collab.grant",
        .summary = "Change what a connected person may do: view, edit or own.",
        .args = &.{ .{ .name = "fingerprint", .type = .string }, .{ .name = "grade", .type = .string } },
        .handler = grantHandler,
        .data = sc,
        .meta = .{ .label = "Set Peer Access", .prompts = true },
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

    // Once that same offer is bound, acceptance degrades to a no-op rather
    // than opening whichever row now occupies its old slot. (Open IS bound:
    // a replica of the quad on this connection — only its base is read.)
    var bound: core.session.Collab = undefined;
    bound.base = 24;
    try conn.collabs.append(gpa, &bound);
    defer conn.collabs.deinit(gpa);
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

test "share-fs echoes the surfaces selected, one by one" {
    const expect = std.testing.expectEqualStrings;
    try expect("not reach the shared filesystem", fsGrantNote(.none));
    try expect("list the shared files", fsGrantNote(.{ .hierarchy = true }));
    try expect("read shared file contents", fsGrantNote(.{ .bytes = true }));
    try expect("write shared files", fsGrantNote(.{ .mutate = true }));
    try expect("list and read the shared files", fsGrantNote(.read));
    try expect("list, read, and write the shared files", fsGrantNote(.read_write));
    // The selection a person types is the one they are told they made.
    try expect("list and write the shared files", fsGrantNote(core.peer_fs.parseGrant("hierarchy,write").?));
}
