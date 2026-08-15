//! scion --headless — the persistent host peer, same binary as the
//! editor (design rev 2: no dedicated agent). Hosts a document, serves
//! the wire protocol (ops/requests/feeds) to N peers as a hub, spawns
//! the language server on the host side (placement `host` made
//! literal), serves range reads for partial checkout, and autosaves.
//! The window/Vulkan half of scion is simply never initialized.
//!
//!   scion --headless --listen PORT [--token T] [--lsp "zls"] [file]

const std = @import("std");
const core = @import("core/core.zig");
const session = core.session;
const capability = core.capability;

pub const Args = struct {
    listen: u16 = 7777,
    token: []const u8 = "scion-dev",
    lsp_cmd: ?[]const u8 = null,
    file: ?[]const u8 = null,
};

pub fn run(gpa: std.mem.Allocator, args: Args, environ: std.process.Environ) !void {
    var pool = try core.task.Pool.init(gpa, .{ .threads = 2 });
    defer pool.deinit();
    var buffers = try core.Buffers.init(gpa, pool, "host");
    defer buffers.deinit(gpa);
    const editor = &buffers.active().editor;
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

    // The minimal command surface the LSP adapter's tick needs.
    var commands: core.command.Commands = .empty;
    defer commands.deinit(gpa);
    var keymap: core.Keymap = .empty;
    defer keymap.deinit(gpa);
    var pick_state: core.Pick = .empty;
    defer pick_state.deinit(gpa);
    var caps = capability.Caps.init(gpa, core.task.nowNs);
    defer caps.deinit();
    var quit = false;
    var echo_line: std.ArrayList(u8) = .empty;
    defer echo_line.deinit(gpa);
    var ctx: core.command.Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .pick = &pick_state,
        .caps = &caps,
        .quit = &quit,
        .echo = &echo_line,
    };

    // Host-side LSP: the server runs WHERE THE DOCUMENT LIVES.
    var lsp: ?*core.lsp.Lsp = null;
    defer if (lsp) |l| l.destroy();
    if (args.lsp_cmd) |cmd_str| {
        if (editor.backingPath()) |p| {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(gpa);
            var words = std.mem.tokenizeScalar(u8, cmd_str, ' ');
            while (words.next()) |w| try argv.append(gpa, w);
            lsp = core.lsp.Lsp.create(gpa, argv.items, p, &editor.doc, environ) catch |err| blk: {
                std.log.warn("headless: lsp unavailable: {t}", .{err});
                break :blk null;
            };
            if (lsp) |l| {
                const layer = try caps.registerFeed(&editor.doc, "edit/diagnostics", "diagnostics", .host, "lsp/server");
                l.attachDiagnostics(layer);
            }
        }
    }

    var blob: ?session.BlobServer = null;
    defer if (blob) |*b| b.close();
    if (editor.backingPath()) |p| blob = session.BlobServer.openPath(p) catch null;

    // ── Hub: accept forever, serve N peers on the one document ──
    std.log.info("headless: listening on {d}", .{args.listen});
    const listener = try session.tcpListener(args.listen);
    var hub: Hub = .{ .gpa = gpa };
    defer hub.deinit();
    const accept_thread = try std.Thread.spawn(.{}, acceptMain, .{ &hub, listener });
    accept_thread.detach(); // dies with the process (accept has no clean cancel)

    var park: std.atomic.Value(u32) = .init(0);
    var last_change_ns: u64 = 0;
    var seen_commits: usize = 0;
    while (!quit) {
        // Adopt newly accepted connections.
        var pending = hub.incoming.swap(null, .acquire);
        while (pending) |node| {
            pending = node.next;
            const fd = node.fd;
            gpa.destroy(node);
            hub.adopt(fd, args.token, &editor.doc, &caps, if (blob != null) &blob.? else null) catch |err| {
                std.log.warn("headless: peer setup failed: {t}", .{err});
            };
        }
        // Tick everyone; broadcast falls out of per-peer frontier
        // tracking (a batch merged from one peer moves the head, so
        // every other Collab sends on its next tick).
        var i: usize = 0;
        while (i < hub.clients.items.len) {
            const c = hub.clients.items[i];
            _ = c.conn.tick() catch {};
            if (c.sess.liveness() == .offline) {
                std.log.info("headless: peer departed ({d} left)", .{hub.clients.items.len - 1});
                hub.remove(i);
            } else i += 1;
        }
        if (lsp) |l| _ = try l.tick(&ctx);
        _ = editor.pollSave(gpa);
        if (editor.doc.commitCount() != seen_commits) {
            seen_commits = editor.doc.commitCount();
            last_change_ns = core.task.nowNs();
        }
        if (last_change_ns != 0 and core.task.nowNs() - last_change_ns > 2 * std.time.ns_per_s) {
            last_change_ns = 0;
            if (editor.backingPath() != null) try editor.requestSave(gpa);
        }
        parkNs(&park, 15 * std.time.ns_per_ms);
    }
}

const FdNode = struct { next: ?*FdNode = null, fd: i32 };

const Client = struct {
    hub: *Hub,
    fd_link: session.FdLink,
    sess: *session.Session,
    conn: session.Conn,
};

const Hub = struct {
    gpa: std.mem.Allocator,
    clients: std.ArrayList(*Client) = .empty,
    incoming: std.atomic.Value(?*FdNode) = .init(null),

    fn deinit(self: *Hub) void {
        for (self.clients.items) |c| {
            c.conn.deinit();
            c.sess.destroy();
            self.gpa.destroy(c);
        }
        self.clients.deinit(self.gpa);
        var cur = self.incoming.swap(null, .acquire);
        while (cur) |n| {
            cur = n.next;
            _ = std.os.linux.close(n.fd);
            self.gpa.destroy(n);
        }
    }

    fn adopt(
        self: *Hub,
        fd: i32,
        token: []const u8,
        doc: *core.Document,
        caps: *capability.Caps,
        blob: ?*session.BlobServer,
    ) !void {
        const gpa = self.gpa;
        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        c.* = .{ .hub = self, .fd_link = .{ .fd = fd }, .sess = undefined, .conn = undefined };
        c.sess = try session.Session.create(gpa, c.fd_link.link(), .server, token);
        errdefer c.sess.destroy();
        c.conn = try session.Conn.init(gpa, c.sess, "host", .server);
        errdefer c.conn.deinit();
        const collab = try c.conn.bindPrimary(doc, 0);
        collab.export_diag_layer = caps.layers.find(doc, "diagnostics");
        collab.blob_server = blob;
        collab.publish_presence = false; // a hub has no cursor
        collab.relay = relayPresence;
        collab.relay_ctx = c;
        try self.clients.append(gpa, c);
        std.log.info("headless: peer joined ({d} connected)", .{self.clients.items.len});
    }

    fn remove(self: *Hub, i: usize) void {
        const c = self.clients.swapRemove(i);
        c.conn.deinit();
        c.sess.destroy();
        self.gpa.destroy(c);
    }
};

/// Presence relay: what one peer publishes, every other peer receives.
fn relayPresence(ctx: ?*anyopaque, key: u64, payload: []const u8) void {
    const sender: *Client = @ptrCast(@alignCast(ctx.?));
    for (sender.hub.clients.items) |c| {
        if (c == sender) continue;
        c.sess.postFeed(1, key, payload) catch {};
    }
}

fn acceptMain(hub: *Hub, listener: i32) void {
    while (true) {
        const fd = session.tcpAccept(listener) catch return;
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
    }
}

fn parkNs(word: *std.atomic.Value(u32), ns: u64) void {
    var ts: std.os.linux.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.os.linux.futex_4arg(&word.raw, .{ .cmd = .WAIT, .private = true }, word.load(.acquire), &ts);
}
