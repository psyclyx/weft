//! Filesystem doors (perm-gated, design §4 Group B/C): local cwd-relative
//! read/write/append/list, plus the async `.peer` list bridge (queued for the
//! frame loop) and the shared buffer-delivery used by both proc output and the
//! peer listing reply.

const std = @import("std");
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const Buffers = @import("../Buffers.zig");
const rooted_fs = @import("../rooted_fs.zig");
const file = @import("../file.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const perm_fs_read = shared.perm_fs_read;
const perm_fs_write = shared.perm_fs_write;

/// `fs.read(path)` (perm fs_read): read a file into the guest, returning the
/// byte count, or -1 (denied / not found / too big for the buffer).
pub fn hFsRead(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!p.perms[perm_fs_read]) {
        results[0] = -1;
        return;
    }
    const path = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(path);
    const bytes = file.readAlloc(p.gpa, path) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(bytes);
    results[0] = @intCast(caller.writeMemory(@intCast(args[2]), @intCast(args[3]), bytes) catch {
        results[0] = -1;
        return;
    });
}

/// `fs.exists(path)` (perm fs_read): what a cwd-relative path is without
/// reading it — 0 absent, 1 file, 2 dir, 3 other; -1 denied. The clean
/// primitive behind project-root detection (climb to the nearest `.git`).
pub fn hFsExists(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!p.perms[perm_fs_read]) {
        results[0] = -1;
        return;
    }
    const path = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(path);
    results[0] = @intFromEnum(file.statKind(p.gpa, path));
}

/// `fs.write(path, bytes)` (perm fs_write): replace a file. 0 ok / -1 denied.
pub fn hFsWrite(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!p.perms[perm_fs_write]) {
        results[0] = -1;
        return;
    }
    const path = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(path);
    const bytes = caller.readMemory(p.gpa, @intCast(args[2]), @intCast(args[3])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(bytes);
    file.writeBytes(p.gpa, path, bytes) catch {
        results[0] = -1;
        return;
    };
    results[0] = 0;
}

/// `fs.append(path, bytes)` (perm fs_write): append to a file (capture). 0/-1.
pub fn hFsAppend(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!p.perms[perm_fs_write]) {
        results[0] = -1;
        return;
    }
    const path = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(path);
    const bytes = caller.readMemory(p.gpa, @intCast(args[2]), @intCast(args[3])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(bytes);
    file.appendBytes(p.gpa, path, bytes) catch {
        results[0] = -1;
        return;
    };
    results[0] = 0;
}

/// `fs.list(authority, path, out, cap)` (perm fs_read) → n or -1. Locus-routed:
/// `"here"` lists the LOCAL path via rooted_fs (confined to that dir); `.shell`/
/// `.peer` authorities route to ShellFs / the peer_fs client once the collab
/// transport is wired (they return -1 here, so a guest degrades, never reads the
/// wrong locus). Directories keep a trailing `/`; entries are newline-joined.
pub fn hFsList(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!p.perms[perm_fs_read]) {
        results[0] = -1;
        return;
    }
    const auth = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(auth);
    const path = caller.readMemory(p.gpa, @intCast(args[2]), @intCast(args[3])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(path);
    // Only the local tier is served here; a remote authority degrades to -1
    // (the path carries the locus — we never silently fall back to local).
    if (!std.mem.eql(u8, auth, "here")) {
        results[0] = -1;
        return;
    }
    const pz = p.gpa.dupeZ(u8, path) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(pz);
    var fs = rooted_fs.RootedFs.open(pz.ptr) catch {
        results[0] = -1;
        return;
    };
    defer fs.close();
    const listing = fs.list(p.gpa, ".") catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(listing);
    results[0] = @intCast(caller.writeMemory(@intCast(args[4]), @intCast(args[5]), listing) catch 0);
}

/// `fs.list_async(authority, path, dest)` (perm fs_read) → 0 queued / -1. The
/// async remote door: for a `"peer"` authority, queue a LIST that the frame
/// loop posts over the connected session and delivers into the `dest` buffer
/// (round-2 D1 — never a blocking round-trip on the frame thread). A local
/// authority uses the synchronous `fs.list` instead, so this returns -1 for it.
pub fn hFsListAsync(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!p.perms[perm_fs_read]) {
        results[0] = -1;
        return;
    }
    const auth = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(auth);
    const path = caller.readMemory(p.gpa, @intCast(args[2]), @intCast(args[3])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(path);
    const dest = caller.readMemory(p.gpa, @intCast(args[4]), @intCast(args[5])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(dest);
    const bridge = g_peer_fs orelse {
        results[0] = -1;
        return;
    };
    if (!std.mem.eql(u8, auth, "peer")) {
        results[0] = -1;
        return;
    }
    bridge.enqueue(path, dest);
    results[0] = 0;
}

/// Find-or-create the named buffer and replace its whole content with `content`,
/// authored as `author` (grade-gated) — the shared delivery used by proc output
/// and the async `.peer` fs listing. Frame-thread only.
pub fn deliverToBuffer(ctx: *command.Context, buf_name: []const u8, author: []const u8, content: []const u8) void {
    const gpa = ctx.gpa;
    const bufs = ctx.buffers;
    var target: ?*Buffers.Buffer = null;
    var it = bufs.iterator();
    while (it.next()) |b| {
        if (std.mem.eql(u8, b.name, buf_name)) {
            target = b;
            break;
        }
    }
    if (target == null) {
        const id = bufs.create(gpa, buf_name) catch return;
        target = bufs.get(id);
    }
    const b = target orelse return;
    const doc = &b.editor.doc;
    const end = b.editor.text().byteLen();
    // Proc output + peer-listing delivery, authored as the plugin peer.
    command.renderInto(gpa, doc, .plugin, author, &.{.{ .range = .{ .start = 0, .end = end }, .bytes = content }}) catch return;
}

/// Bridge for the async `.peer` filesystem: the guest queues LIST requests
/// (path + destination buffer name) here; the frame loop drains them, posts
/// them over the connected session's RemoteFs, and delivers each reply into the
/// named buffer. Kept name-based (no plugin pointer), so a plugin unloading
/// mid-flight can never cause a use-after-free (round-2 D1).
pub const PeerFsBridge = struct {
    gpa: std.mem.Allocator,
    requests: std.ArrayList(Req) = .empty,

    pub const Req = struct { path: []u8, dest: []u8 };

    pub fn deinit(self: *PeerFsBridge) void {
        for (self.requests.items) |r| {
            self.gpa.free(r.path);
            self.gpa.free(r.dest);
        }
        self.requests.deinit(self.gpa);
    }
    fn enqueue(self: *PeerFsBridge, path: []const u8, dest: []const u8) void {
        const pd = self.gpa.dupe(u8, path) catch return;
        const dd = self.gpa.dupe(u8, dest) catch {
            self.gpa.free(pd);
            return;
        };
        self.requests.append(self.gpa, .{ .path = pd, .dest = dd }) catch {
            self.gpa.free(pd);
            self.gpa.free(dd);
        };
    }
};
var g_peer_fs: ?*PeerFsBridge = null;
pub fn setPeerFsBridge(b: ?*PeerFsBridge) void {
    g_peer_fs = b;
}
