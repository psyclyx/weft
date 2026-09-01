//! Filesystem doors (perm-gated, design §4 Group B/C): local cwd-relative
//! read/write/append/list, plus the async `.peer` list bridge (queued for the
//! frame loop) and the shared buffer-delivery used by both proc output and the
//! peer listing reply.
//!
//! **W0b split (doc/extensibility-native-surface.md, task W0b item 1 — the perm-gated
//! representative set)**: `fsRead`/`fsExists`/`fsWrite`/`fsAppend`/`fsList`
//! below are the SEMANTIC bodies — guard (`shared.hasPerm`) + native-typed
//! state access, zero wasm awareness (no `*wasm.Caller`, no ptr+len, no
//! marshalling) — and `hFsRead`/etc. are thin wasm TRAMPOLINES: decode args
//! out of guest memory, call the semantic body, encode the result (or trap on
//! `error.PermissionDenied`). This is the ONE body per import the split
//! demands (doc/extensibility-native-surface.md: "the wasm path and the
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
//! oversight (see doc/cwa-prior-docs-audit.md §5). It is also
//! left OUT of the limit enforcement below: it only ever serves the
//! `.peer` authority (a REMOTE root, already the collab session's own
//! confinement, see `PeerFsBridge`), never `"here"` — a local `.fs_root`
//! grant has nothing to say about it.
//!
//! **Absent means CONFINED (doc/place.md §4.1, the last item of the place
//! arc).** A declared-but-unnarrowed `fs_read`/`fs_write` no longer reaches
//! the whole machine. `grants.defaultLimit` mints `Limit.place` for both, and
//! `gate` below resolves that AT THE DOOR against `Context.place()` — so the
//! confinement follows the dispatch instead of being baked at grant time, and
//! a plugin acting in project A cannot read project B with no config change at
//! all. The place's directory comes from `shared.placeRootFor`, the SAME
//! reading `wl_place_root`/`wl_place_has` answer with, so what a guest is told
//! about and what it is confined to cannot disagree. Once resolved, a `.place`
//! is confined by the identical two layers `.fs_root` gets (below) — there is
//! no second path-comparison in this file.
//!
//! Unconfined survives, as something you WRITE DOWN: `weft.grant(who, cap,
//! { root: "/" })` normalizes to `Limit.none` (`grants.limitForRoot`) and
//! reaches everything the machinery carve-out does not. That is the escape
//! hatch, and it is in the approval diff.
//!
//! **Limit enforcement (doc/contextual-workspace-architecture.md §13.5, task
//! #8's item 1):** after the `hasPerm` possession check, each of the five
//! split bodies below reads the checked handle's resolved bounds (`gate`) and,
//! for a confined one, narrows `path` to its root before touching the
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
//!      write paths" bar): ALL FIVE limited branches route their actual
//!      I/O through `RootedFs`, so a symlink planted inside a limited root
//!      can leak or corrupt NOTHING through any of them.
//! **`fsExists` is confined exactly as its four siblings are** (it was not
//! always: through W4 its limited branch stopped at layer 1 and answered
//! with the plain, UNCONFINED `file.statKind`, so a symlink planted inside
//! the root leaked the *kind* of a target outside it, and a `root = "."`
//! grant — `rootRelative`'s whole-cwd case, where layer 1 is a no-op by
//! construction — confined it not at all, which is precisely what the
//! `.git` climb in `guest/git.zig` and `guest/project.zig` ran on before
//! `wl_place_has` retired both climbs and both grants). It now
//! stats the ALREADY-OPEN confined descriptor (`RootedFs.kind`: `O_PATH`
//! under the same `openat2`, then `statx(AT_EMPTY_PATH)`) instead of the
//! raw path, so "does this exist, and what is it" is answerable for
//! exactly the set of paths `fsRead` would hand over bytes for — one
//! confinement, five doors, no door that merely describes what the others
//! refuse.
//!
//! **The machinery carve-out (doc/place.md §4/§4.1), ahead of all of it.**
//! The limit machinery above is about how WIDE a grant is. The editor's own
//! state on disk — the module cache, the plugin kv store, the identity and
//! known-peers keystores (`core/machinery.zig`) — is outside that question
//! entirely: no grant reaches it, however broad, and narrowing a grant to an
//! `fs_root` is not what makes it safe. `gate` below enforces that FIRST,
//! before possession and before the limit, and it is the only way a body in
//! this file can obtain a `Limit` at all — so "an fs door that forgot the
//! carve-out" is not a shape this file can express. `error.Machinery` is a
//! distinct third refusal, never a mundane miss, so `fsExists` cannot be
//! used to probe for machinery it may not read.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const Buffers = @import("../Buffers.zig");
const rooted_fs = @import("../rooted_fs.zig");
const file = @import("../file.zig");
const grants_mod = @import("../grants.zig");
const machinery = @import("../machinery.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const requirePerm = shared.requirePerm;

/// The denial signals a semantic body below returns: `PermissionDenied` on a
/// missing/revoked grant (the ORIGINAL, W0b-era signal), `OutOfLimit` on a
/// possessed-but-out-of-bounds `.fs_root` path (task #8 / W4 slice 2 — see
/// this file's module doc's "Limit enforcement" section), `Machinery` on a
/// path that is the editor's OWN state, which no grant reaches (doc/place.md
/// §4.1 — see this file's module doc's carve-out paragraph). The wasm
/// trampolines turn ANY of the three into a trap —
/// `shared.trapPermDenied`/`trapOutOfLimit`/`trapMachinery` — so they stay
/// distinguishable in the trap message; an in-process caller lets any of them
/// propagate as an ordinary Zig error (C17: structure against MISTAKES on
/// both transports, no sandbox to trap into off-wasm — see
/// `InProcClient.zig`'s module doc).
pub const PermError = error{ PermissionDenied, OutOfLimit, Machinery };

/// A path buffer for the ONE place a `.place` limit resolves against. Sized
/// like `machinery.zig`'s, so no directory a door could actually open
/// overflows it.
const PathBuf = [std.fs.max_path_bytes]u8;

/// What a body may act on, once `gate` has answered — the RESOLVED form of a
/// `Limit`, which is why a body never sees a `Limit` at all.
///
/// `Limit.place` in particular can never reach a body: it names no root (it is
/// "wherever this dispatch is"), so the gate resolves it into one before
/// handing anything back. A body cannot forget to, because a body has no way
/// to obtain the unresolved form.
const Bounds = union(enum) {
    /// The whole filesystem, minus the machinery carve-out. Reachable ONLY
    /// from an explicit `weft.grant(who, cap, { root: "/" })` (`grants.zig`'s
    /// `unconfined_root`) — never from saying nothing.
    unconfined,
    /// Confined beneath a root.
    within: Within,
    /// Nothing is in bounds. Two causes, both fail-closed: a limit that is not
    /// fs-path-shaped riding an fs capability (a `.doc_region`/`.graph_subtree`
    /// row — a malformed or mismatched limit denies rather than degrading to
    /// unconfined), and a `.place` whose place has NO local directory (a peer
    /// or synthetic container: the honest answer is a refusal, not a silent
    /// run in the editor's launch directory).
    closed,
};

/// A resolved confinement root, plus how a RELATIVE path is read against it.
const Within = struct {
    /// Borrowed for the call — cwd-relative for `.fs_root` (as authored),
    /// absolute for a place (as the authority that opened it named it).
    root: []const u8,
    /// True when `root` came from the dispatching PLACE rather than from a
    /// literal `.fs_root` string. The two read a relative path differently,
    /// and the difference is the whole point of the variant:
    ///   - `.fs_root("notes")` says a path must be SPELLED inside `notes/`,
    ///     because that is the string the grant author wrote.
    ///   - `.place` says a relative path IS place-relative — `weft-notes.md`
    ///     means the notes file of the project you are in. In the degenerate
    ///     `.process` place that is byte-identical to today's cwd-relative
    ///     reading; in any other place it is what makes one grant follow the
    ///     user from project to project.
    place_rooted: bool,

    /// `path`'s root-relative remainder to hand `RootedFs`, or `null` = out of
    /// bounds. The LEXICAL layer only — see this file's module doc; the kernel
    /// gate is what actually resolves it.
    fn relative(self: Within, path: []const u8) ?[]const u8 {
        if (!self.place_rooted) return rootRelative(self.root, path);
        // A place root is absolute, so an ABSOLUTE path must name this place
        // (ordinary prefix work), while a RELATIVE one is already inside it by
        // construction and has nothing to strip.
        const rel = if (path.len > 0 and path[0] == '/')
            rootRelative(self.root, path) orelse return null
        else
            path;
        // `..` never survives a place. The kernel gate refuses a climb that
        // ESCAPES, but `pathAllowed` (the JS plane's descriptor-free variant)
        // has no kernel to ask, and a place must mean the same thing at both
        // doors. Conservative in the documented direction: this can only ever
        // falsely DENY (a `sub/../file` that never actually leaves).
        return if (climbs(rel)) null else rel;
    }
};

/// Does `rel` contain a `..` component? See `Within.relative`.
fn climbs(rel: []const u8) bool {
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |c| if (std.mem.eql(u8, c, "..")) return true;
    return false;
}

/// The ONE gate every door in this file passes, in the order the three
/// questions actually rank:
///
///   1. **Is this the editor's own machinery?** Unconditional. Asked before
///      any grant is consulted, so a broader grant cannot widen it and a
///      narrower one is not what makes it safe (doc/place.md §4.1: "Bucket 1
///      is carved out unconditionally: no grant, however broad, reaches the
///      module cache or the keystores").
///   2. **Is the capability possessed?** `hasPerm`, exactly as before.
///   3. **How wide is it, HERE?** The possessed `Limit`, resolved against
///      this dispatch's place and handed back for the body to confine with.
///
/// Returning the bounds is the point: a body has no other way to obtain them,
/// so it cannot reach step 3 without having passed steps 1 and 2. That is
/// what makes the carve-out structural rather than a convention five call
/// sites have to remember.
///
/// `scratch` backs the resolved place directory when the limit is `.place`;
/// the returned `Within.root` may point into it, so it must outlive the call
/// that uses the bounds.
fn gate(id: anytype, comptime perm: shared.Perm, path: []const u8, scratch: []u8) PermError!Bounds {
    if (machinery.denies(path)) return error.Machinery;
    if (!shared.hasPerm(id, perm)) return error.PermissionDenied;
    return switch (shared.limitFor(id, perm)) {
        .none => .unconfined,
        .place => blk: {
            const dir = shared.placeRootFor(id, scratch);
            if (dir.len == 0) break :blk .closed;
            break :blk .{ .within = .{ .root = dir, .place_rooted = true } };
        },
        .fs_root => |root| .{ .within = .{ .root = root, .place_rooted = false } },
        .doc_region, .graph_subtree => .closed,
    };
}

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

/// The gate MINUS the kernel layer, for a caller that has NO file descriptor
/// to root against — `quickjs.zig`'s `cFileRead` answering out of a LIVE
/// buffer rather than off disk, and `cAgentWrite`, which never touches the
/// filesystem at all. Same three questions in the same order as `gate`
/// (machinery first, unconditionally), so the JS plane cannot end up with a
/// different fs policy than the wasm plane: a JS plugin is not a different
/// kind of plugin (doc/place.md §4.1a). Returns the REASON rather than a
/// bool, so a caller physically cannot report a machinery refusal as "outside
/// the granted root". Fails closed on a limit kind that isn't fs-path-shaped,
/// and on a `.place` with no local directory, exactly like the bodies below.
///
/// With no kernel layer, a `.place` confinement here is the lexical rule
/// ALONE. That is why `Within.relative` refuses a `..` component outright
/// rather than deferring it to `openat2` the way `.fs_root` does: a place must
/// mean the same thing at both doors, and the door without a descriptor is the
/// one that sets the bar.
pub fn pathAllowed(id: anytype, comptime perm: shared.Perm, path: []const u8) PermError!void {
    var scratch: PathBuf = undefined;
    switch (try gate(id, perm, path, &scratch)) {
        .unconfined => {},
        .within => |w| if (w.relative(path) == null) return error.OutOfLimit,
        .closed => return error.OutOfLimit,
    }
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
    var scratch: PathBuf = undefined;
    switch (try gate(id, .fs_read, path, &scratch)) {
        .unconfined => return file.readAlloc(gpa, path) catch null,
        .within => |w| {
            const rel = w.relative(path) orelse return error.OutOfLimit;
            var rfs = openLimitedRoot(gpa, w.root) orelse return null;
            defer rfs.close();
            const relz = gpa.dupeZ(u8, rel) catch return null;
            defer gpa.free(relz);
            return rfs.read(gpa, relz.ptr) catch |e| switch (e) {
                error.Confined => error.OutOfLimit,
                else => null,
            };
        },
        // A `.doc_region` limit is a TEXT-EDIT-shaped narrowing (W4 slice 3)
        // — it never legitimately rides an fs_read/fs_write grant, and a
        // place with no local directory has no root to confine against. Both
        // fail CLOSED, not open: a malformed/mismatched/unresolvable limit
        // denies rather than silently degrading to unconfined access.
        .closed => return error.OutOfLimit,
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
            error.Machinery => shared.trapMachinery(p, caller, .fs_read, path),
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
/// `Kind` enum ordinal).
///
/// It used to be the primitive behind project-root detection, and that is what
/// kept `fs_read` on `git` and `project`: a grant over the whole filesystem,
/// to probe for `.git` inside the user's own project. Both now ask
/// `wl_place_has` (`wasm_host/proc.zig`), which is ungated and confined to the
/// place — so what remains here is genuine raw-path access, wanted by callers
/// that really do name a path anywhere their grant reaches.
pub fn fsExists(gpa: Allocator, id: anytype, path: []const u8) PermError!file.Kind {
    var scratch: PathBuf = undefined;
    switch (try gate(id, .fs_read, path, &scratch)) {
        .unconfined => return file.statKind(gpa, path),
        .within => |w| {
            // BOTH layers, exactly like `fsRead` below it: the lexical gate,
            // then the kernel one. A probe must not be able to describe what
            // a read could not fetch — see this file's module doc.
            const rel = w.relative(path) orelse return error.OutOfLimit;
            var rfs = openLimitedRoot(gpa, w.root) orelse return .none;
            defer rfs.close();
            const relz = gpa.dupeZ(u8, rel) catch return .none;
            defer gpa.free(relz);
            const k = rfs.kind(relz.ptr) catch |e| switch (e) {
                error.Confined => return error.OutOfLimit,
                // NotFound and mundane I/O are what "absent" already means
                // here (`file.statKind` swallows both the same way) — the
                // ONE thing that must stay distinguishable is refusal.
                else => return .none,
            };
            return switch (k) {
                .file => .file,
                .dir => .dir,
                .other => .other,
            };
        },
        .closed => return error.OutOfLimit, // see `fsRead`'s doc: fail closed on a mismatched or unresolvable limit
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
            error.Machinery => shared.trapMachinery(p, caller, .fs_read, path),
        }
        return;
    };
    results[0] = @intFromEnum(kind);
}

/// `fs.stat(path)` semantic body (perm fs_read): `fsExists`'s answer plus the
/// rest of the metadata — size, mtime, permission bits, link count. Confined
/// by the SAME `gate` and the SAME two layers as its five siblings, which is
/// the whole reason this is a door here rather than a new `statKind` caller
/// somewhere convenient: a probe that describes a file must never reach a
/// file `fsRead` would refuse to hand over (this file's module doc, and the
/// symlink test `fsExists` already carries — extended to this door).
///
/// Mundane failure is `Stat.absent` (kind 0), never an error: only a REFUSAL
/// is exceptional here. Core interprets none of the fields — see `file.Stat`.
pub fn fsStat(gpa: Allocator, id: anytype, path: []const u8) PermError!file.Stat {
    var scratch: PathBuf = undefined;
    switch (try gate(id, .fs_read, path, &scratch)) {
        .unconfined => return file.statFull(gpa, path),
        .within => |w| {
            const rel = w.relative(path) orelse return error.OutOfLimit;
            var rfs = openLimitedRoot(gpa, w.root) orelse return .absent;
            defer rfs.close();
            const relz = gpa.dupeZ(u8, rel) catch return .absent;
            defer gpa.free(relz);
            const s = rfs.stat(relz.ptr) catch |e| switch (e) {
                error.Confined => return error.OutOfLimit,
                // NotFound and mundane I/O are what "absent" means, exactly
                // as in `fsExists`; the ONE thing that stays distinguishable
                // is refusal.
                else => return .absent,
            };
            return .{
                .kind = switch (s.kind) {
                    .file => .file,
                    .dir => .dir,
                    .other => .other,
                },
                .mode = s.mode,
                .size = s.size,
                .mtime_ns = s.mtime_ns,
                .nlink = s.nlink,
            };
        },
        .closed => return error.OutOfLimit, // see `fsRead`'s doc: fail closed on a mismatched or unresolvable limit
    }
}

/// `wl_fs_stat`'s wire record — 32 bytes, little-endian, fixed layout, no
/// framing. A guest reads it out of its own linear memory with the same
/// `(ptr,cap)` convention every bulk door here uses; the trailing word is
/// reserved so one more field can land without a second door.
pub const stat_record_len = 32;

fn encodeStat(s: file.Stat, out: *[stat_record_len]u8) void {
    std.mem.writeInt(u32, out[0..4], @intCast(@intFromEnum(s.kind)), .little);
    std.mem.writeInt(u32, out[4..8], s.mode, .little);
    std.mem.writeInt(u64, out[8..16], s.size, .little);
    std.mem.writeInt(i64, out[16..24], s.mtime_ns, .little);
    std.mem.writeInt(u32, out[24..28], s.nlink, .little);
    std.mem.writeInt(u32, out[28..32], 0, .little); // reserved
}

pub fn hFsStat(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const path = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(path);
    const s = fsStat(p.gpa, p, path) catch |e| {
        switch (e) {
            error.PermissionDenied => shared.trapPermDenied(p, caller, .fs_read),
            error.OutOfLimit => shared.trapOutOfLimit(p, caller, .fs_read, path),
            error.Machinery => shared.trapMachinery(p, caller, .fs_read, path),
        }
        return;
    };
    // A short destination is -1, never a partial record: half a size is a
    // worse answer than no answer (`wl_pick_outcome_*`'s exact-read rule,
    // applied to the one door here whose payload is not self-describing).
    if (@as(usize, @intCast(args[3])) < stat_record_len) {
        results[0] = -1;
        return;
    }
    var rec: [stat_record_len]u8 = undefined;
    encodeStat(s, &rec);
    results[0] = @intCast(caller.writeMemory(@intCast(args[2]), @intCast(args[3]), &rec) catch {
        results[0] = -1;
        return;
    });
}

/// `fs.write(path, bytes)` semantic body (perm fs_write): replace a file.
/// `true` ok / `false` on a mundane failure.
pub fn fsWrite(gpa: Allocator, id: anytype, path: []const u8, bytes: []const u8) PermError!bool {
    var scratch: PathBuf = undefined;
    switch (try gate(id, .fs_write, path, &scratch)) {
        .unconfined => {
            file.writeBytes(gpa, path, bytes) catch return false;
            return true;
        },
        .within => |w| {
            const rel = w.relative(path) orelse return error.OutOfLimit;
            var rfs = openLimitedRoot(gpa, w.root) orelse return false;
            defer rfs.close();
            const relz = gpa.dupeZ(u8, rel) catch return false;
            defer gpa.free(relz);
            rfs.write(relz.ptr, bytes) catch |e| switch (e) {
                error.Confined => return error.OutOfLimit,
                else => return false,
            };
            return true;
        },
        .closed => return error.OutOfLimit, // see `fsRead`'s doc: fail closed on a mismatched or unresolvable limit
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
            error.Machinery => shared.trapMachinery(p, caller, .fs_write, path),
        }
        return;
    };
    results[0] = if (ok) 0 else -1;
}

/// `fs.append(path, bytes)` semantic body (perm fs_write): append to a file
/// (capture). `true` ok / `false` on a mundane failure.
pub fn fsAppend(gpa: Allocator, id: anytype, path: []const u8, bytes: []const u8) PermError!bool {
    var scratch: PathBuf = undefined;
    switch (try gate(id, .fs_write, path, &scratch)) {
        .unconfined => {
            file.appendBytes(gpa, path, bytes) catch return false;
            return true;
        },
        .within => |w| {
            const rel = w.relative(path) orelse return error.OutOfLimit;
            var rfs = openLimitedRoot(gpa, w.root) orelse return false;
            defer rfs.close();
            const relz = gpa.dupeZ(u8, rel) catch return false;
            defer gpa.free(relz);
            rfs.append(relz.ptr, bytes) catch |e| switch (e) {
                error.Confined => return error.OutOfLimit,
                else => return false,
            };
            return true;
        },
        .closed => return error.OutOfLimit, // see `fsRead`'s doc: fail closed on a mismatched or unresolvable limit
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
            error.Machinery => shared.trapMachinery(p, caller, .fs_write, path),
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
    // `gate` runs even for a non-`"here"` authority, so the carve-out stays
    // the first thing every door in this file does. Nothing is lost: a
    // remote authority answers `null` on the very next line regardless, and
    // a refusal is a better answer than a miss either way.
    var scratch: PathBuf = undefined;
    const bounds = try gate(id, .fs_read, path, &scratch);
    if (!std.mem.eql(u8, authority, "here")) return null;
    switch (bounds) {
        .unconfined => {
            const pz = gpa.dupeZ(u8, path) catch return null;
            defer gpa.free(pz);
            var fs = rooted_fs.RootedFs.open(pz.ptr) catch return null;
            defer fs.close();
            return fs.list(gpa, ".") catch null;
        },
        .closed => return error.OutOfLimit, // see `fsRead`'s doc: fail closed on a mismatched or unresolvable limit
        .within => |w| {
            const rel = w.relative(path) orelse return error.OutOfLimit;
            var rfs = openLimitedRoot(gpa, w.root) orelse return null;
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
            error.Machinery => shared.trapMachinery(p, caller, .fs_read, path),
        }
        return;
    } orelse {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(listing);
    results[0] = @intCast(caller.writeMemory(@intCast(args[4]), @intCast(args[5]), listing) catch 0);
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

test "Within.relative: a PLACE root reads a relative path as place-relative; an fs_root does not" {
    const place: Within = .{ .root = "/home/u/proj", .place_rooted = true };
    const literal: Within = .{ .root = "/home/u/proj", .place_rooted = false };

    // The one behavioural difference between the two roots, and the reason
    // `place_rooted` is a field rather than a comment: `weft-notes.md` means
    // "this project's notes file" under a place, and means nothing at all
    // under a root the author spelled out.
    try t.expectEqualStrings("weft-notes.md", place.relative("weft-notes.md").?);
    try t.expect(literal.relative("weft-notes.md") == null);

    // An ABSOLUTE path must name the place either way — same prefix work.
    try t.expectEqualStrings("a.txt", place.relative("/home/u/proj/a.txt").?);
    try t.expectEqualStrings(".", place.relative("/home/u/proj").?);
    try t.expect(place.relative("/home/u/other/a.txt") == null);
    try t.expect(place.relative("/etc/passwd") == null);
    // The boundary nit, inherited from `rootRelative`: a sibling whose name
    // merely starts with the place's is not in the place.
    try t.expect(place.relative("/home/u/proj-elsewhere/a.txt") == null);

    // A climb is refused LEXICALLY under a place, in both spellings, because
    // `pathAllowed` has no kernel to ask and the two doors must agree.
    try t.expect(place.relative("../secret") == null);
    try t.expect(place.relative("sub/../../secret") == null);
    try t.expect(place.relative("/home/u/proj/../secret") == null);
    // …and the same conservatism applies to a climb that never actually
    // leaves. Denying it is the documented direction to be wrong in.
    try t.expect(place.relative("sub/../a.txt") == null);
    // An `.fs_root` grant's behaviour is UNCHANGED: it still hands a `..`
    // remainder through for the kernel gate to decide.
    try t.expectEqualStrings("../escape", rootRelative("notes", "notes/../escape").?);
}

/// The minimal principal `hasPerm`/`limitFor` accept — they duck-type over a
/// FIELD shape, not a nominal type (see `plugin.zig`'s `hasPerm` doc), so a
/// confinement test needs no wasm instance and no `command.Context` behind
/// it, only a live grant table and the handle into it.
const TestPrincipal = struct {
    perms: [WasmPlugin.perm_count]bool = @splat(false),
    grant_table: ?*grants_mod.HandleTable = null,
    grant_handles: [WasmPlugin.perm_count]grants_mod.CapHandle = @splat(grants_mod.CapHandle.none),
};

/// `link_path` → `target`, best effort. Returns false if the platform
/// refused (nothing in these tests depends on symlinks being creatable).
fn makeSymlink(target: [*:0]const u8, link_path: [*:0]const u8) bool {
    return std.os.linux.errno(std.os.linux.symlinkat(target, std.os.linux.AT.FDCWD, link_path)) == .SUCCESS;
}

test "fsExists: a symlink planted INSIDE the root cannot report on a target outside it" {
    const gpa = t.allocator;

    // <tmp>/root          — the granted root
    // <tmp>/secret.txt    — outside it
    // <tmp>/root/leak     — a symlink inside the root, pointing out of it
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/root", .{tmp.sub_path});
    defer gpa.free(root);
    const inside = try std.fmt.allocPrint(gpa, "{s}/ok.txt", .{root});
    defer gpa.free(inside);
    const outside = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/secret.txt", .{tmp.sub_path});
    defer gpa.free(outside);
    try file.writeBytesMakingDirs(gpa, root, inside, "in root");
    try file.writeBytes(gpa, outside, "out of root");
    const leak = try std.fmt.allocPrintSentinel(gpa, "{s}/leak", .{root}, 0);
    defer gpa.free(leak);
    if (!makeSymlink("../secret.txt", leak.ptr)) return error.SkipZigTest;

    var table = grants_mod.HandleTable.init(gpa);
    defer table.deinit();
    var id: TestPrincipal = .{ .grant_table = &table };
    id.grant_handles[shared.perm_fs_read] =
        try table.grant(.{ .capability = "fs_read", .limit = .{ .fs_root = root } }, "confined", null);

    // The symlink itself resolves (a plain stat would follow it straight to
    // `<tmp>/secret.txt`) — but it leaves the root, so the probe is REFUSED,
    // not answered. Before this was closed it returned `.file`: the kind of
    // a file the grant has no business describing.
    try t.expectError(error.OutOfLimit, fsExists(gpa, &id, leak));
    // The read door already refused it. Both doors now agree, which is the
    // whole point — an existence probe must not describe what a read cannot
    // fetch.
    try t.expectError(error.OutOfLimit, fsRead(gpa, &id, leak));

    // ...and the fix is confinement, not blanket refusal: ordinary in-root
    // probes still answer, including the absent one.
    try t.expectEqual(file.Kind.file, try fsExists(gpa, &id, inside));
    try t.expectEqual(file.Kind.dir, try fsExists(gpa, &id, root));
    const missing = try std.fmt.allocPrint(gpa, "{s}/nope.txt", .{root});
    defer gpa.free(missing);
    try t.expectEqual(file.Kind.none, try fsExists(gpa, &id, missing));
}

test "fsStat: confined exactly as fsExists is, and it actually carries the metadata" {
    const gpa = t.allocator;

    // The same three-file fixture the symlink test above builds: a granted
    // root, a secret outside it, and a link inside pointing out.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/root", .{tmp.sub_path});
    defer gpa.free(root);
    const inside = try std.fmt.allocPrint(gpa, "{s}/ok.txt", .{root});
    defer gpa.free(inside);
    const outside = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/secret.txt", .{tmp.sub_path});
    defer gpa.free(outside);
    try file.writeBytesMakingDirs(gpa, root, inside, "in root");
    // Deliberately a DIFFERENT length from the in-root file: a stat that
    // leaked through the link would be caught by the size alone.
    try file.writeBytes(gpa, outside, "out of root, and considerably longer");
    const leak = try std.fmt.allocPrintSentinel(gpa, "{s}/leak", .{root}, 0);
    defer gpa.free(leak);
    if (!makeSymlink("../secret.txt", leak.ptr)) return error.SkipZigTest;

    var table = grants_mod.HandleTable.init(gpa);
    defer table.deinit();
    var id: TestPrincipal = .{ .grant_table = &table };
    id.grant_handles[shared.perm_fs_read] =
        try table.grant(.{ .capability = "fs_read", .limit = .{ .fs_root = root } }, "confined", null);

    // The whole reason this is a door in `fs.zig` and not a `statFull` call
    // somewhere convenient: describing a file must not reach further than
    // reading it. All three doors agree about the link.
    try t.expectError(error.OutOfLimit, fsStat(gpa, &id, leak));
    try t.expectError(error.OutOfLimit, fsExists(gpa, &id, leak));
    try t.expectError(error.OutOfLimit, fsRead(gpa, &id, leak));

    // …and confinement, not blanket refusal: an in-root file answers with
    // real metadata.
    const s = try fsStat(gpa, &id, inside);
    try t.expectEqual(file.Kind.file, s.kind);
    try t.expectEqual(@as(u64, "in root".len), s.size);
    try t.expect(s.mtime_ns > 0);
    try t.expect(s.nlink >= 1);
    try t.expect(s.mode & ~file.mode_mask == 0); // permission bits only — the type rides `kind`

    // A directory, and an absent path: absence is DATA (kind 0), never an
    // error, exactly as `fsExists` answers `.none`.
    try t.expectEqual(file.Kind.dir, (try fsStat(gpa, &id, root)).kind);
    const missing = try std.fmt.allocPrint(gpa, "{s}/nope.txt", .{root});
    defer gpa.free(missing);
    try t.expectEqual(file.Stat.absent, try fsStat(gpa, &id, missing));
}

test "fsStat: a `root = \".\"` grant confines it, and the machinery carve-out precedes the grant" {
    const gpa = t.allocator;
    var table = grants_mod.HandleTable.init(gpa);
    defer table.deinit();
    var id: TestPrincipal = .{ .grant_table = &table };
    id.grant_handles[shared.perm_fs_read] =
        try table.grant(.{ .capability = "fs_read", .limit = .{ .fs_root = "." } }, "cwd-only", null);

    // Layer 1 has nothing to say about a whole-cwd root; the kernel gate is
    // the only check, and it is enough — the same hole `fsExists` closed.
    try t.expectError(error.OutOfLimit, fsStat(gpa, &id, "/etc/passwd"));
    try t.expectError(error.OutOfLimit, fsStat(gpa, &id, "../"));

    // In cwd it answers, with a size a caller can act on.
    const s = try fsStat(gpa, &id, "build.zig");
    try t.expectEqual(file.Kind.file, s.kind);
    try t.expect(s.size > 0);
    try t.expectEqual(file.Kind.dir, (try fsStat(gpa, &id, "src")).kind);
    try t.expectEqual(file.Stat.absent, try fsStat(gpa, &id, "definitely-not-here-xyzzy"));
}

test "fsExists: a `root = \".\"` grant confines it — the whole-cwd case is a kernel gate, not a no-op" {
    const gpa = t.allocator;

    // `rootRelative(".", path)` hands `path` back unchanged: layer 1 has
    // nothing to say about a whole-cwd root. That made `.` a grant that
    // confined `fs_read`/`fs_write`/`fs_append`/`fs_list` but told
    // `fs_exists` NOTHING — and root detection (`guest/git.zig`,
    // `guest/project.zig`) was built entirely out of `fsExists` at the time.
    // Those two now ask `wl_place_has` and hold no grant at all; the hole this
    // closes is still real for every OTHER `fs_exists` caller.
    var table = grants_mod.HandleTable.init(gpa);
    defer table.deinit();
    var id: TestPrincipal = .{ .grant_table = &table };
    id.grant_handles[shared.perm_fs_read] =
        try table.grant(.{ .capability = "fs_read", .limit = .{ .fs_root = "." } }, "cwd-only", null);

    // Absolute: rejected in the kernel (RESOLVE_BENEATH → EXDEV), where it
    // used to be answered `.dir`.
    try t.expectError(error.OutOfLimit, fsExists(gpa, &id, "/etc"));
    // Traversal out of cwd: same refusal.
    try t.expectError(error.OutOfLimit, fsExists(gpa, &id, "../"));
    try t.expectError(error.OutOfLimit, fsExists(gpa, &id, "../../etc"));

    // Inside cwd, the grant still answers — `.` means "all of cwd", and it
    // still does.
    try t.expectEqual(file.Kind.file, try fsExists(gpa, &id, "build.zig"));
    try t.expectEqual(file.Kind.dir, try fsExists(gpa, &id, "src"));
    try t.expectEqual(file.Kind.none, try fsExists(gpa, &id, "definitely-not-here-xyzzy"));
}

test {
    std.testing.refAllDecls(@This());
}
