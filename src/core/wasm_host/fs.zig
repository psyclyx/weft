//! Filesystem doors (perm-gated, design §4 Group B/C): local cwd-relative
//! read/write/append/list, plus the async `.peer` list bridge (queued for the
//! frame loop) and the shared buffer-delivery used by both proc output and the
//! peer listing reply.
//!
//! **W0b split (doc/north-star-plan.md §2.5, task W0b item 1 — the perm-gated
//! representative set)**: `fsRead`/`fsExists`/`fsWrite`/`fsAppend`/`fsList`
//! below are the SEMANTIC bodies — guard (`shared.hasPerm`) + native-typed
//! state access, zero wasm awareness (no `*wasm.Caller`, no ptr+len, no
//! marshalling) — and `hFsRead`/etc. are thin wasm TRAMPOLINES: decode args
//! out of guest memory, call the semantic body, encode the result (or trap on
//! `error.PermissionDenied`). This is the ONE body per import the split
//! demands (doc/north-star-plan.md §2.5 W0b: "the wasm path and the
//! in-process path may not diverge"). One acknowledged deviation from
//! byte-identical: the guard now runs INSIDE the body (after arg decode),
//! where the pre-split trampolines checked before readMemory — observable
//! only when a call is denied AND carries a malformed guest pointer (base:
//! trap-on-deny; now: the decode's own failure path). Benign either way (a
//! guest fault regardless); noted so the claim stays honest.
//! `core/inproc/InProcClient.zig` calls
//! these same five functions directly, with native `[]const u8` paths/bytes
//! and no encode/decode step at all.
//!
//! `hFsListAsync` (the `.peer` queue-and-return-later door) is deliberately
//! LEFT UNSPLIT: its "semantics" are entirely about DEFERRING past this
//! call's return (queue now, the frame loop's collab tick delivers the reply
//! into a named buffer later) — a shape that exists because a wasm guest has
//! no way to block for the round trip. An in-process client has no such
//! constraint (it can simply call the synchronous path, or await the same
//! bridge directly) — forcing this handler into the same
//! guard+native-body+encode shape as the other five would manufacture an
//! in-process "async" primitive nothing needs yet. Honest boundary, not an
//! oversight (see doc/north-star-plan.md's W0b honesty note).

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const Buffers = @import("../Buffers.zig");
const rooted_fs = @import("../rooted_fs.zig");
const file = @import("../file.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const requirePerm = shared.requirePerm;

/// The one denial signal every semantic body below returns on a missing
/// grant — the wasm trampolines turn it into a trap (`shared.trapPermDenied`);
/// an in-process caller lets it propagate as an ordinary Zig error (C17:
/// structure against MISTAKES on both transports, no sandbox to trap into
/// off-wasm — see `InProcClient.zig`'s module doc).
pub const PermError = error{PermissionDenied};

/// `fs.read(path)` semantic body (perm fs_read): the file's bytes, owned by
/// the caller, or `null` for a mundane failure (not found, read error) —
/// `PermissionDenied` is the ONLY error, reserved for the guard.
pub fn fsRead(gpa: Allocator, id: anytype, path: []const u8) PermError!?[]u8 {
    if (!shared.hasPerm(id, .fs_read)) return error.PermissionDenied;
    return file.readAlloc(gpa, path) catch null;
}

pub fn hFsRead(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const path = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(path);
    const bytes = fsRead(p.gpa, p, path) catch {
        shared.trapPermDenied(p, caller, .fs_read);
        return;
    } orelse {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(bytes);
    results[0] = @intCast(caller.writeMemory(@intCast(args[2]), @intCast(args[3]), bytes) catch {
        results[0] = -1;
        return;
    });
}

/// `fs.exists(path)` semantic body (perm fs_read): what a cwd-relative path
/// is without reading it — 0 absent, 1 file, 2 dir, 3 other (`file.statKind`'s
/// `Kind` enum ordinal). The clean primitive behind project-root detection
/// (climb to the nearest `.git`).
pub fn fsExists(gpa: Allocator, id: anytype, path: []const u8) PermError!file.Kind {
    if (!shared.hasPerm(id, .fs_read)) return error.PermissionDenied;
    return file.statKind(gpa, path);
}

pub fn hFsExists(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const path = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(path);
    const kind = fsExists(p.gpa, p, path) catch {
        shared.trapPermDenied(p, caller, .fs_read);
        return;
    };
    results[0] = @intFromEnum(kind);
}

/// `fs.write(path, bytes)` semantic body (perm fs_write): replace a file.
/// `true` ok / `false` on a mundane failure.
pub fn fsWrite(gpa: Allocator, id: anytype, path: []const u8, bytes: []const u8) PermError!bool {
    if (!shared.hasPerm(id, .fs_write)) return error.PermissionDenied;
    file.writeBytes(gpa, path, bytes) catch return false;
    return true;
}

pub fn hFsWrite(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
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
    const ok = fsWrite(p.gpa, p, path, bytes) catch {
        shared.trapPermDenied(p, caller, .fs_write);
        return;
    };
    results[0] = if (ok) 0 else -1;
}

/// `fs.append(path, bytes)` semantic body (perm fs_write): append to a file
/// (capture). `true` ok / `false` on a mundane failure.
pub fn fsAppend(gpa: Allocator, id: anytype, path: []const u8, bytes: []const u8) PermError!bool {
    if (!shared.hasPerm(id, .fs_write)) return error.PermissionDenied;
    file.appendBytes(gpa, path, bytes) catch return false;
    return true;
}

pub fn hFsAppend(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
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
    const ok = fsAppend(p.gpa, p, path, bytes) catch {
        shared.trapPermDenied(p, caller, .fs_write);
        return;
    };
    results[0] = if (ok) 0 else -1;
}

/// `fs.list(authority, path)` semantic body (perm fs_read): newline-joined
/// directory entries (directories keep a trailing `/`), or `null` for a
/// mundane failure. Locus-routed: `"here"` lists the LOCAL path via
/// rooted_fs (confined to that dir); every other authority (`.shell`/
/// `.peer`) degrades to `null` here — a guest/in-process caller reading a
/// remote locus goes through the async door instead (see this file's module
/// doc on why `list_async` stays unsplit).
pub fn fsList(gpa: Allocator, id: anytype, authority: []const u8, path: []const u8) PermError!?[]u8 {
    if (!shared.hasPerm(id, .fs_read)) return error.PermissionDenied;
    if (!std.mem.eql(u8, authority, "here")) return null;
    const pz = gpa.dupeZ(u8, path) catch return null;
    defer gpa.free(pz);
    var fs = rooted_fs.RootedFs.open(pz.ptr) catch return null;
    defer fs.close();
    return fs.list(gpa, ".") catch null;
}

pub fn hFsList(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
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
    const listing = fsList(p.gpa, p, auth, path) catch {
        shared.trapPermDenied(p, caller, .fs_read);
        return;
    } orelse {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(listing);
    results[0] = @intCast(caller.writeMemory(@intCast(args[4]), @intCast(args[5]), listing) catch 0);
}

/// `fs.list_async(authority, path, dest)` (perm fs_read, trap on deny) → 0
/// queued / -1. The async remote door: for a `"peer"` authority, queue a LIST
/// that the frame loop posts over the connected session and delivers into the
/// `dest` buffer (round-2 D1 — never a blocking round-trip on the frame
/// thread). A local authority uses the synchronous `fs.list` instead, so this
/// returns -1 for it.
pub fn hFsListAsync(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!requirePerm(p, caller, .fs_read)) return;
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
    const b = bufs.get(bufs.ensureNamed(gpa, buf_name) catch return) orelse return;
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
