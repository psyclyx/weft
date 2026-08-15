//! scion-agent — the headless host peer. Hosts a worktree document,
//! serves the wire protocol (ops/requests/feeds), spawns the language
//! server on the host side (placement `host` made literal), serves
//! range reads for partial checkout, and autosaves.
//!
//! Dependency graph is the enforcement: this root imports core files
//! only — no snail, no Vulkan, no Wayland, no Lua, no tree-sitter. A
//! stray import fails the build because those modules/libraries are
//! simply not wired into this target.
//!
//!   scion-agent --listen PORT [--token T] [--lsp "zls"] [file]

const std = @import("std");
const Editor = @import("core/Editor.zig");
const Document = @import("core/Document.zig");
const task = @import("core/task.zig");
const session = @import("core/session.zig");
const secure = @import("core/secure.zig");
const capability = @import("core/capability.zig");
const command = @import("core/command.zig");
const Keymap = @import("core/Keymap.zig");
const pick = @import("core/pick.zig");
const lsp_mod = @import("core/lsp.zig");

const Args = struct {
    listen: u16 = 7777,
    token: []const u8 = "scion-dev",
    lsp_cmd: ?[]const u8 = null,
    file: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const debug_alloc = @import("builtin").mode == .Debug;
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_alloc) {
        _ = gpa_state.deinit();
    };
    const gpa = if (debug_alloc) gpa_state.allocator() else std.heap.c_allocator;

    var args: Args = .{};
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--listen")) {
            if (it.next()) |v| args.listen = std.fmt.parseInt(u16, v, 10) catch args.listen;
        } else if (std.mem.eql(u8, a, "--token")) {
            args.token = it.next() orelse args.token;
        } else if (std.mem.eql(u8, a, "--lsp")) {
            args.lsp_cmd = it.next() orelse args.lsp_cmd;
        } else {
            args.file = a;
        }
    }

    var pool = try task.Pool.init(gpa, .{ .threads = 2 });
    defer pool.deinit();
    var editor = try Editor.init(gpa, pool, "agent");
    defer editor.deinit(gpa);
    if (args.file) |p| {
        editor.openFile(gpa, p) catch |err| switch (err) {
            error.FileNotFound => editor.path = try gpa.dupe(u8, p),
            else => |e| return e,
        };
        std.log.info("agent: hosting {s} ({d} bytes)", .{ p, editor.text().byteLen() });
    }

    // The minimal command surface the LSP adapter's tick needs.
    var commands: command.Commands = .empty;
    defer commands.deinit(gpa);
    var keymap: Keymap = .empty;
    defer keymap.deinit(gpa);
    var pick_state: pick.Pick = .empty;
    defer pick_state.deinit(gpa);
    var caps = capability.Caps.init(gpa, task.nowNs);
    defer caps.deinit();
    var quit = false;
    var ctx: command.Context = .{
        .gpa = gpa,
        .editor = &editor,
        .commands = &commands,
        .keymap = &keymap,
        .pick = &pick_state,
        .caps = &caps,
        .quit = &quit,
    };

    // Host-side LSP: the server runs WHERE THE DOCUMENT LIVES.
    var lsp: ?*lsp_mod.Lsp = null;
    defer if (lsp) |l| l.destroy();
    if (args.lsp_cmd) |cmd_str| {
        if (editor.path) |p| {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(gpa);
            var words = std.mem.tokenizeScalar(u8, cmd_str, ' ');
            while (words.next()) |w| try argv.append(gpa, w);
            lsp = lsp_mod.Lsp.create(gpa, argv.items, p, &editor.doc, init.minimal.environ) catch |err| blk: {
                std.log.warn("agent: lsp unavailable: {t}", .{err});
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
    if (editor.path) |p| blob = session.BlobServer.openPath(p) catch null;

    // ── Hub: accept forever, serve N peers on the one document ──
    std.log.info("agent: listening on {d}", .{args.listen});
    const listener = try session.tcpListener(args.listen);
    var hub: Hub = .{ .gpa = gpa };
    defer hub.deinit();
    const accept_thread = try std.Thread.spawn(.{}, acceptMain, .{ &hub, listener });
    accept_thread.detach(); // dies with the process (accept has no clean cancel)

    var park: std.atomic.Value(u32) = .init(0);
    var last_change_ns: u64 = 0;
    var seen_commits: usize = 0;
    while (true) {
        // Adopt newly accepted connections.
        var pending = hub.incoming.swap(null, .acquire);
        while (pending) |node| {
            pending = node.next;
            const fd = node.fd;
            gpa.destroy(node);
            hub.adopt(fd, args.token, &editor.doc, &caps, if (blob != null) &blob.? else null) catch |err| {
                std.log.warn("agent: peer setup failed: {t}", .{err});
            };
        }
        // Tick everyone; broadcast falls out of per-peer frontier
        // tracking (a batch merged from one peer moves the head, so
        // every other Collab sends on its next tick).
        var i: usize = 0;
        while (i < hub.clients.items.len) {
            const c = hub.clients.items[i];
            _ = c.collab.tick(0) catch {};
            if (c.sess.liveness() == .offline) {
                std.log.info("agent: peer departed ({d} left)", .{hub.clients.items.len - 1});
                hub.remove(i);
            } else i += 1;
        }
        if (lsp) |l| _ = try l.tick(&ctx);
        _ = editor.pollSave(gpa);
        if (editor.doc.commitCount() != seen_commits) {
            seen_commits = editor.doc.commitCount();
            last_change_ns = task.nowNs();
        }
        if (last_change_ns != 0 and task.nowNs() - last_change_ns > 2 * std.time.ns_per_s) {
            last_change_ns = 0;
            if (editor.path != null) try editor.requestSave(gpa);
        }
        parkNs(&park, 15 * std.time.ns_per_ms);
    }
}

const FdNode = struct { next: ?*FdNode = null, fd: i32 };

const Client = struct {
    hub: *Hub,
    fd_link: session.FdLink,
    sess: *session.Session,
    collab: session.Collab,
};

const Hub = struct {
    gpa: std.mem.Allocator,
    clients: std.ArrayList(*Client) = .empty,
    incoming: std.atomic.Value(?*FdNode) = .init(null),

    fn deinit(self: *Hub) void {
        for (self.clients.items) |c| {
            c.collab.deinit();
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
        doc: *Document,
        caps: *capability.Caps,
        blob: ?*session.BlobServer,
    ) !void {
        const gpa = self.gpa;
        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        c.* = .{ .hub = self, .fd_link = .{ .fd = fd }, .sess = undefined, .collab = undefined };
        c.sess = try session.Session.create(gpa, c.fd_link.link(), .server, token);
        errdefer c.sess.destroy();
        c.collab = try session.Collab.init(gpa, c.sess, doc, "agent");
        c.collab.export_diag_layer = caps.layers.find("diagnostics");
        c.collab.blob_server = blob;
        c.collab.publish_presence = false; // a hub has no cursor
        c.collab.relay = relayPresence;
        c.collab.relay_ctx = c;
        try self.clients.append(gpa, c);
        std.log.info("agent: peer joined ({d} connected)", .{self.clients.items.len});
    }

    fn remove(self: *Hub, i: usize) void {
        const c = self.clients.swapRemove(i);
        c.collab.deinit();
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
