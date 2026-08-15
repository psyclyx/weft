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

    std.log.info("agent: listening on {d}", .{args.listen});
    const fd = try session.tcpListen(args.listen);
    var fd_link: session.FdLink = .{ .fd = fd };
    const sess = try session.Session.create(gpa, fd_link.link(), .server, args.token);
    defer sess.destroy();
    var collab = try session.Collab.init(gpa, sess, &editor.doc, "agent");
    defer collab.deinit();
    collab.export_diag_layer = caps.layers.find("diagnostics");

    var blob: ?session.BlobServer = null;
    defer if (blob) |*b| b.close();
    if (editor.path) |p| {
        blob = session.BlobServer.openPath(p) catch null;
        if (blob != null) collab.blob_server = &blob.?;
    }

    // Serve until the link dies. 15ms cadence; autosave 2s after quiet.
    var park: std.atomic.Value(u32) = .init(0);
    var last_change_ns: u64 = 0;
    var seen_commits: usize = 0;
    while (sess.liveness() != .offline) {
        _ = try collab.tick(0);
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
    std.log.info("agent: peer gone; exiting", .{});
}

fn parkNs(word: *std.atomic.Value(u32), ns: u64) void {
    var ts: std.os.linux.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.os.linux.futex_4arg(&word.raw, .{ .cmd = .WAIT, .private = true }, word.load(.acquire), &ts);
}
