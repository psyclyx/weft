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
//! oversight (see doc/north-star-plan.md's W0b honesty note). It is also
//! left OUT of the limit enforcement below: it only ever serves the
//! `.peer` authority (a REMOTE root, already the collab session's own
//! confinement, see `PeerFsBridge`), never `"here"` — a local `.fs_root`
//! grant has nothing to say about it.
//!
//! **Limit enforcement (north-star-plan §6 W4 slice 2, task #8's item 1):**
//! after the `hasPerm` possession check, each of the five split bodies below
//! reads the checked handle's `Limit` (`shared.limitFor`) and, for
//! `.fs_root(root)`, confines `path` to `root` before touching the
//! filesystem. Two layers, deliberately different costs for a reason:
//!   1. **`rootRelative` — a LEXICAL gate**, pure string comparison, no
//!      syscalls: `path` must literally BE `root` or be prefixed by
//!      `root ++ "/"` (both cwd-relative, matching every path convention
//!      already in this file — an absolute grant root is out of v1's
//!      scope). Fails closed on anything else, including a path that only
//!      lexically resolves inside `root` through an untraveled `..` (e.g.
//!      `"elsewhere/../notes/x"` against root `"notes"` is REJECTED even
//!      though it's harmless) — conservative on purpose: this gate only
//!      ever falsely DENIES, never falsely allows. A miss here is
//!      `error.OutOfLimit`, trapped by `wasm_host/plugin.zig`'s
//!      `trapOutOfLimit` with BOTH the path and the root named.
//!   2. **`RootedFs` — the KERNEL gate**, `openat2(RESOLVE_BENEATH |
//!      RESOLVE_NO_SYMLINKS)` (the same primitive `fsList`'s `"here"`
//!      authority already used, pre-W4), applied to the root-relative
//!      remainder `rootRelative` computed. This is where a `.."`-laden
//!      remainder that STAYS inside `root` (legitimate) is allowed and one
//!      that escapes it (a confused `rootRelative` pass, or plain malice)
//!      is rejected atomically, in the kernel — no TOCTOU window. **The
//!      symlink policy, stated plainly**: `RESOLVE_NO_SYMLINKS` refuses ANY
//!      symlink anywhere in the resolution chain outright — stricter than
//!      "resolve symlinks then verify they land in-root," which still has
//!      to trust userspace to get that verification right. v1 applies this
//!      to BOTH reads and writes uniformly (exceeding the "at minimum for
//!      write paths" bar): `fsRead`/`fsWrite`/`fsAppend`/`fsList`'s limited
//!      branches all route their actual I/O through `RootedFs`, so a
//!      symlink planted inside a limited root can leak or corrupt NOTHING
//!      through those four.
//! **The one named v1 gap**: `fsExists`'s limited branch stops at layer 1
//! (the lexical gate) and answers with the plain, UNCONFINED `file.statKind`
//! — it does not route through `RootedFs`. A symlink planted inside the
//! root could therefore leak the *kind* (file/dir/other/absent) of a target
//! outside it, though never its bytes (that's `fsRead`'s job, which IS
//! confined). Closing this is a small follow-up (stat the already-open
//! confined fd instead of the raw path) — named here rather than silently
//! left, not implemented in this slice to avoid adding new raw-syscall
//! surface (statx flag plumbing) under this task's scope. **The gap is
//! TOTAL for a `root = "."` grant** (`rootRelative`'s whole-cwd case): layer
//! 1 there is a no-op by construction (every cwd-relative path passes it —
//! there is nothing to be lexically "outside" of cwd itself), so a
//! `fs_root("."`)-limited `fsExists` is exactly as unconfined as the
//! pre-W4, no-limit boolean grant was — zero confinement, not "mostly
//! confined with a symlink-shaped hole." A grant author relying on `"."`
//! specifically to restrict `fs_exists` should not: it restricts
//! read/write/append/list (all four route through the kernel gate even at
//! `root = "."`), but tells `fsExists` nothing.

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

/// The denial signals a semantic body below returns: `PermissionDenied` on a
/// missing/revoked grant (the ORIGINAL, W0b-era signal), `OutOfLimit` on a
/// possessed-but-out-of-bounds `.fs_root` path (task #8 / W4 slice 2 — see
/// this file's module doc's "Limit enforcement" section). The wasm
/// trampolines turn EITHER into a trap — `shared.trapPermDenied` for the
/// former, `shared.trapOutOfLimit` for the latter, so the two stay
/// distinguishable in the trap message; an in-process caller lets either
/// propagate as an ordinary Zig error (C17: structure against MISTAKES on
/// both transports, no sandbox to trap into off-wasm — see
/// `InProcClient.zig`'s module doc).
pub const PermError = error{ PermissionDenied, OutOfLimit };

/// The LEXICAL half of `.fs_root` limit enforcement — see this file's
/// module doc's "Limit enforcement" section for the full two-layer policy
/// this is layer 1 of. Returns `path`'s root-relative remainder to hand to
/// `RootedFs`, or `null` = out of limit.
fn rootRelative(root_in: []const u8, path: []const u8) ?[]const u8 {
    // Normalize a trailing slash on `root` (a `.fs_root = "notes/"` grant is
    // a plausible, easy-to-write spelling) — without this, the boundary
    // check below would misread `path[root.len]` one byte past the slash
    // and falsely DENY every in-root path. Fail-closed was safe either way
    // (this file's module doc), but silently rejecting a legitimately
    // in-root path on a cosmetic trailing slash is its own kind of surprise
    // worth just not having.
    const root = if (root_in.len > 1 and root_in[root_in.len - 1] == '/') root_in[0 .. root_in.len - 1] else root_in;
    if (std.mem.eql(u8, root, ".")) return path; // whole-cwd root: the kernel gate (layer 2) is the only check needed
    if (std.mem.eql(u8, root, path)) return ".";
    if (!std.mem.startsWith(u8, path, root)) return null;
    if (path.len == root.len or path[root.len] != '/') return null;
    return path[root.len + 1 ..];
}

/// Layer 1 alone, for a reader that has NO file descriptor to root against
/// — `quickjs.zig`'s `cFileRead` answering out of a LIVE buffer rather than
/// off disk. Fails closed on a limit kind that isn't fs-path-shaped, exactly
/// like the bodies below.
pub fn pathWithinLimit(id: anytype, comptime perm: shared.Perm, path: []const u8) bool {
    return switch (shared.limitFor(id, perm)) {
        .none => true,
        .fs_root => |root| rootRelative(root, path) != null,
        .doc_region, .graph_subtree => false,
    };
}

/// Open the confined root for a `.fs_root(root)` limit (layer 2 — see the
/// module doc). `null` on a missing/inaccessible root: a config/admin
/// problem (the grant names a root that isn't there), not a guest attack,
/// so it degrades exactly like any other mundane fs failure in this file —
/// no trap.
fn openLimitedRoot(gpa: Allocator, root: []const u8) ?rooted_fs.RootedFs {
    const rootz = gpa.dupeZ(u8, root) catch return null;
    defer gpa.free(rootz);
    return rooted_fs.RootedFs.open(rootz.ptr) catch {
        // The silent-third-result doctrine: a missing/inaccessible root is
        // still a MUNDANE degrade (not a guest attack, no trap — see this
        // function's doc), but a config typo silently returning "as if the
        // file doesn't exist" on every call, forever, is its own kind of
        // unfindable bug. One `.warn` per attempt (this fires once per
        // open, not looped internally — "first open" IS the only open) so a
        // misconfigured `.fs_root` grant is diagnosable, not just quiet.
        std.log.warn("wasm_host/fs.zig: a `.fs_root` grant names root '{s}', which isn't an openable directory — every call against it will degrade to a mundane miss until this is fixed", .{root});
        return null;
    };
}

/// `fs.read(path)` semantic body (perm fs_read): the file's bytes, owned by
/// the caller, or `null` for a mundane failure (not found, read error) —
/// `PermissionDenied` is the ONLY error, reserved for the guard.
pub fn fsRead(gpa: Allocator, id: anytype, path: []const u8) PermError!?[]u8 {
    if (!shared.hasPerm(id, .fs_read)) return error.PermissionDenied;
    switch (shared.limitFor(id, .fs_read)) {
        .none => return file.readAlloc(gpa, path) catch null,
        .fs_root => |root| {
            const rel = rootRelative(root, path) orelse return error.OutOfLimit;
            var rfs = openLimitedRoot(gpa, root) orelse return null;
            defer rfs.close();
            const relz = gpa.dupeZ(u8, rel) catch return null;
            defer gpa.free(relz);
            return rfs.read(gpa, relz.ptr) catch |e| switch (e) {
                error.Confined => error.OutOfLimit,
                else => null,
            };
        },
        // A `.doc_region` limit is a TEXT-EDIT-shaped narrowing (W4 slice 3)
        // — it never legitimately rides an fs_read/fs_write grant. Fail
        // CLOSED, not open: a malformed/mismatched limit denies rather than
        // silently degrading to unconfined access.
        // `.graph_subtree` is GraphDoc-shaped, same fail-closed reasoning.
        .doc_region, .graph_subtree => return error.OutOfLimit,
    }
}

pub fn hFsRead(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const path = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(path);
    const bytes = fsRead(p.gpa, p, path) catch |e| {
        switch (e) {
            error.PermissionDenied => shared.trapPermDenied(p, caller, .fs_read),
            error.OutOfLimit => shared.trapOutOfLimit(p, caller, .fs_read, path),
        }
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
    switch (shared.limitFor(id, .fs_read)) {
        .none => return file.statKind(gpa, path),
        .fs_root => |root| {
            // Layer 1 (the lexical gate) only — see this file's module doc's
            // named v1 gap: this stays UNCONFINED at layer 2, so a symlink
            // inside `root` could leak a target's kind (never its bytes).
            _ = rootRelative(root, path) orelse return error.OutOfLimit;
            return file.statKind(gpa, path);
        },
        // `.graph_subtree` is GraphDoc-shaped, same fail-closed reasoning.
        .doc_region, .graph_subtree => return error.OutOfLimit, // see `fsRead`'s doc: fail closed on a mismatched limit shape
    }
}

pub fn hFsExists(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const path = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(path);
    const kind = fsExists(p.gpa, p, path) catch |e| {
        switch (e) {
            error.PermissionDenied => shared.trapPermDenied(p, caller, .fs_read),
            error.OutOfLimit => shared.trapOutOfLimit(p, caller, .fs_read, path),
        }
        return;
    };
    results[0] = @intFromEnum(kind);
}

/// `fs.write(path, bytes)` semantic body (perm fs_write): replace a file.
/// `true` ok / `false` on a mundane failure.
pub fn fsWrite(gpa: Allocator, id: anytype, path: []const u8, bytes: []const u8) PermError!bool {
    if (!shared.hasPerm(id, .fs_write)) return error.PermissionDenied;
    switch (shared.limitFor(id, .fs_write)) {
        .none => {
            file.writeBytes(gpa, path, bytes) catch return false;
            return true;
        },
        .fs_root => |root| {
            const rel = rootRelative(root, path) orelse return error.OutOfLimit;
            var rfs = openLimitedRoot(gpa, root) orelse return false;
            defer rfs.close();
            const relz = gpa.dupeZ(u8, rel) catch return false;
            defer gpa.free(relz);
            rfs.write(relz.ptr, bytes) catch |e| switch (e) {
                error.Confined => return error.OutOfLimit,
                else => return false,
            };
            return true;
        },
        // `.graph_subtree` is GraphDoc-shaped, same fail-closed reasoning.
        .doc_region, .graph_subtree => return error.OutOfLimit, // see `fsRead`'s doc: fail closed on a mismatched limit shape
    }
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
    const ok = fsWrite(p.gpa, p, path, bytes) catch |e| {
        switch (e) {
            error.PermissionDenied => shared.trapPermDenied(p, caller, .fs_write),
            error.OutOfLimit => shared.trapOutOfLimit(p, caller, .fs_write, path),
        }
        return;
    };
    results[0] = if (ok) 0 else -1;
}

/// `fs.append(path, bytes)` semantic body (perm fs_write): append to a file
/// (capture). `true` ok / `false` on a mundane failure.
pub fn fsAppend(gpa: Allocator, id: anytype, path: []const u8, bytes: []const u8) PermError!bool {
    if (!shared.hasPerm(id, .fs_write)) return error.PermissionDenied;
    switch (shared.limitFor(id, .fs_write)) {
        .none => {
            file.appendBytes(gpa, path, bytes) catch return false;
            return true;
        },
        .fs_root => |root| {
            const rel = rootRelative(root, path) orelse return error.OutOfLimit;
            var rfs = openLimitedRoot(gpa, root) orelse return false;
            defer rfs.close();
            const relz = gpa.dupeZ(u8, rel) catch return false;
            defer gpa.free(relz);
            rfs.append(relz.ptr, bytes) catch |e| switch (e) {
                error.Confined => return error.OutOfLimit,
                else => return false,
            };
            return true;
        },
        // `.graph_subtree` is GraphDoc-shaped, same fail-closed reasoning.
        .doc_region, .graph_subtree => return error.OutOfLimit, // see `fsRead`'s doc: fail closed on a mismatched limit shape
    }
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
    const ok = fsAppend(p.gpa, p, path, bytes) catch |e| {
        switch (e) {
            error.PermissionDenied => shared.trapPermDenied(p, caller, .fs_write),
            error.OutOfLimit => shared.trapOutOfLimit(p, caller, .fs_write, path),
        }
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
    switch (shared.limitFor(id, .fs_read)) {
        .none => {
            const pz = gpa.dupeZ(u8, path) catch return null;
            defer gpa.free(pz);
            var fs = rooted_fs.RootedFs.open(pz.ptr) catch return null;
            defer fs.close();
            return fs.list(gpa, ".") catch null;
        },
        // `.graph_subtree` is GraphDoc-shaped, same fail-closed reasoning.
        .doc_region, .graph_subtree => return error.OutOfLimit, // see `fsRead`'s doc: fail closed on a mismatched limit shape
        .fs_root => |root| {
            const rel = rootRelative(root, path) orelse return error.OutOfLimit;
            var rfs = openLimitedRoot(gpa, root) orelse return null;
            defer rfs.close();
            const relz = gpa.dupeZ(u8, rel) catch return null;
            defer gpa.free(relz);
            return rfs.list(gpa, relz.ptr) catch |e| switch (e) {
                error.Confined => error.OutOfLimit,
                else => null,
            };
        },
    }
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
    const listing = fsList(p.gpa, p, auth, path) catch |e| {
        switch (e) {
            error.PermissionDenied => shared.trapPermDenied(p, caller, .fs_read),
            error.OutOfLimit => shared.trapOutOfLimit(p, caller, .fs_read, path),
        }
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
    const ed = b.textEditor() orelse return;
    const doc = &ed.doc;
    const end = ed.text().byteLen();
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

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "rootRelative: the lexical gate — in-root, out-of-root, boundary, and the trailing-slash nit" {
    // Ordinary case: a literal prefix match, boundary-checked.
    try t.expectEqualStrings("x", rootRelative("notes", "notes/x").?);
    try t.expectEqualStrings(".", rootRelative("notes", "notes").?);
    try t.expect(rootRelative("notes", "notes2/x") == null); // "notes2" is NOT "notes" + boundary
    try t.expect(rootRelative("notes", "elsewhere/x") == null);
    // `..` isn't resolved here (that's the kernel's job, layer 2) — a
    // remainder containing `..` is handed through verbatim.
    try t.expectEqualStrings("../escape", rootRelative("notes", "notes/../escape").?);

    // Trailing-slash root: `.fs_root = "notes/"` reads identically to
    // `.fs_root = "notes"` — the normalization nit.
    try t.expectEqualStrings("x", rootRelative("notes/", "notes/x").?);
    try t.expectEqualStrings(".", rootRelative("notes/", "notes").?);

    // Whole-cwd root: nothing to strip, the kernel gate is the only check.
    try t.expectEqualStrings("etc/passwd", rootRelative(".", "etc/passwd").?);
}

test {
    std.testing.refAllDecls(@This());
}
