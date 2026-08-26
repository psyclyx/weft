//! weft --headless — the persistent host peer, same binary as the
//! editor (design rev 2: no dedicated agent). Hosts a document, serves
//! the wire protocol (ops/requests/feeds) to N peers as a hub, spawns
//! the language server on the host side (placement `host` made
//! literal), serves range reads for partial checkout, and autosaves.
//! The window/Vulkan half of weft is simply never initialized.
//!
//! The loop is the SAME `core/scheduler.zig` kernel `main.zig` drives
//! (doc/contextual-workspace-architecture.md §7) — collab (the hub's
//! wake-fd) and pool sources, no window/present sources at all. The old
//! shape here was a fixed 15ms futex park regardless of whether anything
//! was pending; that's gone — an idle host with no peers, no in-flight
//! saves, and nothing dirty genuinely blocks in `poll()` until a peer's
//! reader thread (or the accept thread) signals the hub's eventfd, or the
//! pool signals a finished task, or the autosave-idle deadline (armed only
//! while a change is actually pending) comes due.
//!
//! **W0b's headed/headless gate (doc/cwa-prior-docs-audit.md §5): `sys` below is
//! built with `core.System.create` — the SAME construction `app/session.zig`'s
//! `Session.init` uses for the windowed binary's "editor" system (buffers,
//! commands, keymap, caps, actions, container, the built-in command/keymap
//! floor). This file used to build its own bare `Buffers`+`Container`+`Caps`
//! triple by hand (pre-`System`, an artifact of headless.zig predating the
//! System/Host split) — that divergence meant "headless is the same
//! composition minus the window-head" was ASPIRATIONAL, not literally true.
//! Migrating it onto `core.System.create` closes that gap: the only
//! structural difference between this file and `main.zig` is that NO
//! `app/window_head.zig` `WindowHead` is ever constructed here, and no
//! `core.Head` ever attaches (`sys.default_head` — the same headless
//! dispatch target `agent-ux`, `core/System.zig`'s own "zero-head systems
//! are a first-class resting state" gate, uses — services collab/autosave
//! directly; nothing here injects a keystroke). commands/keymap/actions go
//! unused today (a hub relays bytes, it doesn't dispatch), which is
//! harmless overhead, not dead weight: it is what makes hosting a manifest
//! (a future `--headless --config`) or a second head attaching to THIS
//! system (W4's `head/attach`) additive instead of a rewrite.
//!
//!   weft --headless --listen PORT [--token T] [file]

const std = @import("std");
const core = @import("core/core.zig");
const session = core.session;
const capability = core.capability;
const scheduler = core.scheduler;

pub const Args = struct {
    listen: u16 = 7777,
    access: session.Access = .view,
    token: []const u8 = "weft-dev",
    file: ?[]const u8 = null,
};

pub fn run(gpa: std.mem.Allocator, args: Args, environ: std.process.Environ) !void {
    var pool = try core.task.Pool.init(gpa, .{ .threads = 2 });
    defer pool.deinit();
    // The SAME `core.System` construction the windowed binary hosts as its
    // "editor" system (`app/session.zig`'s `Session.init`) — see module doc.
    const sys = try core.System.create(gpa, pool, "host", "host");
    defer sys.destroy();
    const buffers = &sys.buffers;
    const editor = buffers.active().textEditor().?;
    if (args.file) |p| {
        editor.openFile(gpa, p) catch |err| switch (err) {
            error.FileNotFound => try editor.adoptPath(gpa, p),
            else => |e| return e,
        };
        std.log.info("headless: hosting {s} ({d} bytes)", .{ p, editor.text().byteLen() });
        // Compact at the freshly loaded point: bounds graph growth and
        // makes the content servable as a partial-checkout base (the
        // backing mirror is rebuilt on the new base alongside).
        if (editor.doc.commitCount() > 0) {
            editor.compactNow(gpa) catch |e| {
                std.log.warn("headless: compaction skipped: {t}", .{e});
            };
        }
    }

    const caps = &sys.caps;
    var blob: ?session.BlobServer = null;
    defer if (blob) |*b| b.close();
    if (editor.backingPath()) |p| blob = session.BlobServer.openPath(p) catch null;

    // This host's long-term identity (generated + persisted on first run,
    // headless included), so peers can name and verify us.
    var host_identity = core.identity.loadOrGenerate(gpa, environ) catch |err| blk: {
        std.log.warn("identity: {t} — using an ephemeral one this run", .{err});
        break :blk core.identity.Identity.generate();
    };
    std.log.info("headless identity {s}", .{&host_identity.fingerprint()});

    // Who we've talked to before (TOFU): first contact is accepted but
    // logged as unverified with its SAS, so an operator can confirm it out
    // of band; a returning verified peer is auto-trusted.
    var known = try core.known_peers.KnownPeers.load(gpa, environ);
    defer known.deinit();

    // ── Hub: accept forever, serve N peers on the one document ──
    std.log.info("headless: listening on {d} ({s} access)", .{ args.listen, args.access.label() });
    var hub = try core.hub.Hub.init(gpa, args.token, args.access, &host_identity);
    defer hub.deinit();
    try hub.listen(args.listen);
    var cfg: HeadlessCfg = .{
        .doc = &editor.doc,
        .caps = caps,
        .blob = if (blob != null) &blob.? else null,
    };

    // ── The scheduler: pool completions + the hub's peer-activity signal
    // (new connection, or any peer's inbox gaining data — see hub.zig's
    // `wake_fd` doc) as fd sources; autosave-idle as a deadline source,
    // armed only while a change is actually pending. ──
    var sched = scheduler.Scheduler.init(gpa, core.task.nowNs);
    defer sched.deinit();
    const pool_wake_fd = try scheduler.newWakeFd();
    defer scheduler.closeWakeFd(pool_wake_fd);
    pool.setNotifyFd(pool_wake_fd);
    _ = try sched.addFd(pool_wake_fd, .{ .read = true }, null, null, "pool");
    _ = try sched.addFd(hub.wake_fd, .{ .read = true }, null, null, "hub");

    var loop_state: LoopState = .{
        .hub = &hub,
        .cfg = &cfg,
        .known = &known,
        .editor = editor,
        .gpa = gpa,
    };
    _ = try sched.addTimer(&loop_state, autosaveDue, "autosave_idle");

    // Never returns (no shutdown path today — matches the old `while
    // (true)`; the process is killed externally).
    try sched.run(&loop_state, wake);
}

/// The per-wake body: unchanged from the old per-15ms-tick loop, just run
/// on genuine wakes now instead of a fixed park. Adopt newly accepted
/// connections, then tick everyone; broadcast falls out of per-peer
/// frontier tracking (a batch merged from one peer moves the head, so
/// every other Collab sends on its next tick).
const LoopState = struct {
    hub: *core.hub.Hub,
    cfg: *HeadlessCfg,
    known: *core.known_peers.KnownPeers,
    editor: *core.Editor,
    gpa: std.mem.Allocator,
    last_change_ns: u64 = 0,
    seen_commits: usize = 0,
};

fn wake(ctx: ?*anyopaque) anyerror!void {
    const l: *LoopState = @ptrCast(@alignCast(ctx.?));
    l.hub.acceptPending(l.cfg, headlessConfigure);
    _ = l.hub.tick();
    notePeerIdentities(l.hub, l.known);
    _ = l.editor.pollSave(l.gpa);
    if (l.editor.doc.commitCount() != l.seen_commits) {
        l.seen_commits = l.editor.doc.commitCount();
        l.last_change_ns = core.task.nowNs();
    }
    if (l.last_change_ns != 0 and core.task.nowNs() - l.last_change_ns > 2 * std.time.ns_per_s) {
        l.last_change_ns = 0;
        if (l.editor.backingPath() != null) try l.editor.requestSave(l.gpa);
    }
}

/// Pure query (doc/contextual-workspace-architecture.md §7): dormant while no change is
/// pending; otherwise the same "2s of quiet since the last change" line
/// the old inline compare used, now told to the scheduler instead of
/// discovered by accident on the next 15ms park.
fn autosaveDue(ctx: ?*anyopaque, now: u64) ?u64 {
    _ = now;
    const l: *const LoopState = @ptrCast(@alignCast(ctx.?));
    if (l.last_change_ns == 0) return null;
    return l.last_change_ns + 2 * std.time.ns_per_s;
}

/// Binding policy for a new peer: the headless host serves ONE document
/// (the hosted file) on quad 0, has no cursor of its own (relay only),
/// and serves blobs + host-scoped diagnostics.
const HeadlessCfg = struct {
    doc: *core.Document,
    caps: *capability.Caps,
    blob: ?*session.BlobServer,
};

fn headlessConfigure(ctx: ?*anyopaque, peer: *core.hub.Peer) anyerror!void {
    const cfg: *HeadlessCfg = @ptrCast(@alignCast(ctx.?));
    const collab = try peer.conn.bindPrimary(cfg.doc, 0);
    collab.export_diag_layer = cfg.caps.layers.find(cfg.doc, "diagnostics");
    collab.blob_server = cfg.blob;
    collab.publish_presence = false; // a hub has no cursor
    collab.relay = core.hub.relayPresence;
    collab.relay_ctx = try peer.relayFor(cfg.doc);
}

/// Note each freshly-established peer's identity exactly once: record the
/// TOFU entry and log its fingerprint, SAS, and trust so an operator can
/// verify a newcomer out of band. Cheap to call every wake (the flag
/// gates the work; the fingerprint is only available post-handshake).
fn notePeerIdentities(hub: *core.hub.Hub, known: *core.known_peers.KnownPeers) void {
    for (hub.clients.items) |p| {
        if (p.identity_noted) continue;
        const fp = p.sess.peerFingerprint() orelse continue; // not established yet
        const sas = p.sess.sas() orelse continue;
        p.identity_noted = true;
        const prior = known.remember(fp) catch |err| blk: {
            std.log.warn("known_peers: {t}", .{err});
            break :blk core.known_peers.Trust.unknown;
        };
        if (prior == .verified) {
            std.log.info("headless: verified peer {s} reconnected", .{&fp});
        } else if (prior == .unverified) {
            std.log.info("headless: peer {s} reconnected (unverified) — SAS {s}", .{ &fp, &sas });
        } else {
            std.log.info(
                "headless: NEW peer {s} — SAS {s} — unverified; confirm out of band",
                .{ &fp, &sas },
            );
        }
    }
}
