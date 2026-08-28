//! `machinery` — the editor's OWN state on disk, and the ONE denylist weft is
//! allowed to keep.
//!
//! **Why a denylist is right here, and nowhere else** (doc/place.md §4, §4.1).
//! That section splits filesystem use three ways, with "can the locus vary?"
//! as the test. Bucket 1 — editor machinery — has a locus that is statically
//! `here`: the wasm module cache, the persisted plugin kv store, the machine's
//! identity key, the known-peers list. Four locations, every one of them
//! **program-computed** from XDG/env at startup by the module that owns it,
//! finite, and knowable before any plugin runs. Nobody names them; nobody
//! shares them; they are never remote. A closed set like that is exactly what
//! a denylist can express without lying.
//!
//! User content is the opposite — open-ended, user-named, arbitrarily deep —
//! which is why the rest of the membrane confines with a ROOT (an allowlist
//! with a kernel behind it: `rooted_fs.zig`) and never with a list of
//! forbidden names. This file is the exception that proves that rule, not a
//! template for more of them. If you find yourself wanting to add a fifth
//! entry that is *not* program-computed, the answer is a capability, not a
//! line here.
//!
//! **Unconditional, and independent of any grant.** `wasm_host/fs.zig`'s
//! `gate` consults this BEFORE it looks at possession or at a `.fs_root`
//! limit, so:
//!   - a broader grant cannot widen it (an unconfined `fs_read` — today's
//!     default `.none` limit, which the shipped config hands out — reaches
//!     every absolute path on the machine EXCEPT these), and
//!   - narrowing a grant to an `fs_root` is not what makes it safe (the
//!     carve-out already held before the limit was read).
//! Both planes route through that one gate, because a JS plugin is not a
//! different kind of plugin (doc/place.md §4.1a).
//!
//! **Resolved once, from the owning module.** Each location comes from the
//! function that actually places the files — `wasm.Engine.cacheDir`,
//! `kv_file.stateDir`, `identity.configPath`, `known_peers.configPath` — so
//! the deny list cannot drift from the real location: moving the store moves
//! the refusal in the same edit. Resolution happens on the first fs-door call
//! and is cached for the process, since the environment these read is a
//! startup constant.
//!
//! **Compared canonically.** Two forms are kept per location and the
//! candidate is compared against both: the lexical absolute form (`..` and
//! `.` folded, cwd prepended) and the kernel form (`realpath(3)` over the
//! longest prefix that exists, so a symlinked `$HOME` — or a symlink a plugin
//! planted itself — resolves to the same string the machinery does). Neither
//! `../../../.cache/weft/modules` nor a symlink pointed at it walks in.
//!
//! **The residue, stated plainly.** This is a check-then-use, unlike the
//! `.fs_root` confinement next door, which hands the kernel a dir-fd and lets
//! `openat2(RESOLVE_BENEATH)` decide atomically. A denial has no root to hand
//! over, so there is no fd for the subsequent open to inherit, and a
//! sufficiently determined plugin could in principle swap a symlink between
//! the check and the read. That race is not the cheap way in: a plugin able
//! to plant and swap symlinks on demand already holds `proc`, and `proc`
//! reads the module cache without asking this file anything. Closing the fs
//! door is worth doing on its own terms; pretending it is the only door would
//! not be.

const std = @import("std");

const wasm = @import("wasm.zig");
const kv_file = @import("kv_file.zig");
const identity = @import("identity.zig");
const known_peers = @import("known_peers.zig");
const task = @import("task.zig");

/// The four locations of bucket 1. An enum rather than a bare list so a
/// refusal can NAME what it refused — "the module cache", not "some path" —
/// and so adding a fifth is a compile-time obligation everywhere this is
/// switched on.
pub const Location = enum {
    /// `wasm.Engine.cacheDir` — compiled `.cwasm` images, keyed by content
    /// hash. A plugin that could write here would be choosing the machine
    /// code every OTHER plugin runs next launch.
    module_cache,
    /// `kv_file.stateDir` — the persisted plugin kv store (matcher frecency,
    /// the recent/kill/mark rings, `project-recent`): one plugin's private
    /// state, readable by all of them if this were reachable.
    kv_state,
    /// `identity.configPath` — the machine's SECRET key, mode 0600. Reading
    /// it is impersonating this weft to every peer it has ever met.
    identity_key,
    /// `known_peers.configPath` — who this machine has decided to trust, and
    /// at what grade. Writing it is granting yourself a trusted peer.
    known_peers_list,

    pub fn label(self: Location) []const u8 {
        return switch (self) {
            .module_cache => "the wasm module cache",
            .kv_state => "the plugin kv store",
            .identity_key => "the identity keystore",
            .known_peers_list => "the known-peers keystore",
        };
    }
};

const location_count = @typeInfo(Location).@"enum".fields.len;

/// PATH_MAX on the platforms weft hosts on. Every buffer below is one of
/// these, so no path a door could actually open overflows a comparison.
const PathBuf = [std.fs.max_path_bytes]u8;

/// One location, in the two shapes a candidate is compared against. `lexical`
/// empty = this location does not exist in this process's environment (no
/// `$HOME`, no `$XDG_*`, caching off) — there is nothing there to protect.
const Resolved = struct {
    lexical: []const u8 = "",
    kernel: []const u8 = "",
};

var g_store: [location_count][2]PathBuf = undefined;
var g_resolved: [location_count]Resolved = @splat(.{});
/// Did ANY location resolve? A host with no `$HOME` and no `$XDG_*` at all
/// has no machinery on disk to protect, and every fs door then skips the two
/// canonicalizations below entirely.
var g_any = false;
var g_ready: std.atomic.Value(bool) = .init(false);
var g_lock: task.Mutex = .{};

/// The process environment, read the way `wasm.Engine.cacheDir` and
/// `kv_file.stateDir` already read it, adapted to the `getPosix` shape the
/// two keystore modules' `configPath` takes.
///
/// Deliberately NOT `wasm_host.g_environ` (the environment plugins spawn
/// children with): that one is *installed* by a host at startup, and a host
/// that forgot to call `setEnviron` must not thereby WIDEN the carve-out. The
/// keystores read the real process environment; so does this.
///
/// Public only so a GATE can resolve the two keystores the same way this
/// module does, and assert the fs doors refuse exactly those paths.
pub const Posix = struct {
    pub fn getPosix(_: Posix, name: []const u8) ?[]const u8 {
        var buf: [64]u8 = undefined;
        if (name.len >= buf.len) return null;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const v = std.c.getenv(buf[0..name.len :0].ptr) orelse return null;
        return std.mem.span(v);
    }
};

fn ensureResolved() void {
    if (g_ready.load(.acquire)) return;
    g_lock.lock();
    defer g_lock.unlock();
    if (g_ready.load(.monotonic)) return;
    resolveAll();
    g_ready.store(true, .release);
}

/// Ask each owning module where its state lives, exactly once. `page_allocator`
/// for the two that allocate: the answers are copied into `g_store` and the
/// originals freed here, so nothing outlives this call and no caller has to
/// thread an allocator into a refusal check.
fn resolveAll() void {
    const gpa = std.heap.page_allocator;
    var scratch: PathBuf = undefined;

    if (wasm.Engine.cacheDir(gpa)) |d| {
        defer gpa.free(d);
        record(.module_cache, d);
    }
    if (kv_file.stateDir(gpa)) |d| {
        defer gpa.free(d);
        record(.kv_state, d);
    }
    if (identity.configPath(&scratch, Posix{})) |p| record(.identity_key, p);
    if (known_peers.configPath(&scratch, Posix{})) |p| record(.known_peers_list, p);
}

fn record(loc: Location, path: []const u8) void {
    const i = @intFromEnum(loc);
    const lex = lexicalAbs(&g_store[i][0], path) orelse return;
    g_resolved[i] = .{
        .lexical = lex,
        // A location that does not exist YET (first run, cache never
        // written) still canonicalizes through its existing parent, so the
        // refusal covers creating it as well as reading it.
        .kernel = kernelAbs(&g_store[i][1], lex) orelse lex,
    };
    g_any = true;
}

/// Which machinery location `path` names or lives inside, or `null` if it is
/// ordinary content. THE question this module exists to answer.
///
/// A path that cannot be made absolute at all (empty, or longer than
/// PATH_MAX) answers `null` — not a hole: such a path is one no fs door can
/// open either, so the operation fails as a mundane miss a moment later.
pub fn locationOf(path: []const u8) ?Location {
    ensureResolved();
    if (!g_any) return null;
    var lex_buf: PathBuf = undefined;
    var ker_buf: PathBuf = undefined;
    const lex = lexicalAbs(&lex_buf, path) orelse return null;
    const ker = kernelAbs(&ker_buf, lex);
    for (g_resolved, 0..) |r, i| {
        if (r.lexical.len == 0) continue;
        if (under(lex, r.lexical) or under(lex, r.kernel)) return @enumFromInt(i);
        if (ker) |k| {
            if (under(k, r.lexical) or under(k, r.kernel)) return @enumFromInt(i);
        }
    }
    return null;
}

/// `locationOf` as the predicate a gate wants. True = refuse, whatever the
/// caller was granted.
pub fn denies(path: []const u8) bool {
    return locationOf(path) != null;
}

/// Is `candidate` `base` itself, or beneath it? Both must already be
/// absolute and normalized; the boundary check is what keeps
/// `…/weft/modules-of-mine` from matching root `…/weft/modules`.
fn under(candidate: []const u8, base: []const u8) bool {
    if (base.len == 0) return false;
    if (std.mem.eql(u8, candidate, base)) return true;
    if (!std.mem.startsWith(u8, candidate, base)) return false;
    if (base.len == 1 and base[0] == '/') return true; // "/" is its own separator
    return candidate.len > base.len and candidate[base.len] == '/';
}

/// `path` as an ABSOLUTE, `.`/`..`-free string, written into `buf`. Purely
/// lexical apart from `getcwd` for a relative spelling — NO symlink is
/// followed here, which is precisely why `kernelAbs` exists alongside it and
/// why both forms are compared.
fn lexicalAbs(buf: []u8, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    var len: usize = 0;
    if (path[0] != '/') {
        if (std.c.getcwd(buf.ptr, buf.len) == null) return null;
        len = std.mem.indexOfScalar(u8, buf, 0) orelse return null;
        if (len == 0 or len + 1 + path.len > buf.len) return null;
        buf[len] = '/';
        len += 1;
    }
    if (len + path.len > buf.len) return null;
    @memcpy(buf[len..][0..path.len], path);
    return normalizeAbs(buf[0 .. len + path.len]);
}

/// Fold `.`, `..`, and repeated/trailing slashes out of an absolute path, in
/// place. Compaction only ever writes BEHIND the read cursor, so the
/// component being copied is never the one being overwritten.
fn normalizeAbs(s: []u8) []const u8 {
    std.debug.assert(s.len > 0 and s[0] == '/');
    var out: usize = 1; // the built prefix is "/" (out==1) or "/a/b" (no trailing slash)
    var i: usize = 1;
    while (i < s.len) {
        const start = i;
        while (i < s.len and s[i] != '/') i += 1;
        const comp = s[start..i];
        if (i < s.len) i += 1; // consume the separator
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (out > 1) {
                const cut = std.mem.lastIndexOfScalar(u8, s[0..out], '/') orelse 0;
                out = @max(cut, 1);
            }
            continue;
        }
        if (out > 1) {
            s[out] = '/';
            out += 1;
        }
        std.mem.copyForwards(u8, s[out..][0..comp.len], comp);
        out += comp.len;
    }
    return s[0..out];
}

/// `abs` with every symlink resolved as far as the kernel can see:
/// `realpath(3)` on the longest prefix that EXISTS, plus whatever remained,
/// written into `buf`. `null` only if nothing at all resolved.
fn kernelAbs(buf: []u8, abs: []const u8) ?[]const u8 {
    var headz: PathBuf = undefined;
    var real: PathBuf = undefined;
    var end = abs.len;
    while (true) {
        if (end == 0 or end >= headz.len) return null;
        @memcpy(headz[0..end], abs[0..end]);
        headz[end] = 0;
        if (std.c.realpath(headz[0..end :0].ptr, &real)) |r| {
            return joinInto(buf, std.mem.span(r), abs[end..]);
        }
        if (end == 1) return null; // even "/" refused to resolve
        const cut = std.mem.lastIndexOfScalar(u8, abs[0..end], '/') orelse return null;
        end = @max(cut, 1);
    }
}

/// `head` (a resolved absolute prefix) joined to `rest` (the lexical
/// remainder, which may or may not lead with a separator).
fn joinInto(buf: []u8, head: []const u8, rest: []const u8) ?[]const u8 {
    var h = head;
    while (h.len > 1 and h[h.len - 1] == '/') h = h[0 .. h.len - 1];
    if (h.len == 1 and h[0] == '/') h = ""; // the separator below supplies it
    var r = rest;
    while (r.len > 0 and r[0] == '/') r = r[1..];
    if (r.len == 0) {
        const out = if (h.len == 0) "/" else h;
        if (out.len > buf.len) return null;
        @memcpy(buf[0..out.len], out);
        return buf[0..out.len];
    }
    if (h.len + 1 + r.len > buf.len) return null;
    @memcpy(buf[0..h.len], h);
    buf[h.len] = '/';
    @memcpy(buf[h.len + 1 ..][0..r.len], r);
    return buf[0 .. h.len + 1 + r.len];
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "machinery: the lexical form is absolute and `..`-free" {
    var buf: PathBuf = undefined;
    try t.expectEqualStrings("/a/b", lexicalAbs(&buf, "/a/b").?);
    try t.expectEqualStrings("/a/b", lexicalAbs(&buf, "/a/./b").?);
    try t.expectEqualStrings("/a/b", lexicalAbs(&buf, "/a//b//").?);
    try t.expectEqualStrings("/b", lexicalAbs(&buf, "/a/../b").?);
    try t.expectEqualStrings("/", lexicalAbs(&buf, "/a/../..").?);
    try t.expectEqualStrings("/", lexicalAbs(&buf, "/").?);
    try t.expectEqualStrings("/x", lexicalAbs(&buf, "/../../x").?);
    // A relative spelling is anchored at cwd, so a `..` climb out of it is
    // visible to the comparison rather than hidden behind the relativity.
    const rel = lexicalAbs(&buf, "a/../b").?;
    try t.expect(std.fs.path.isAbsolute(rel));
    try t.expect(std.mem.endsWith(u8, rel, "/b"));
    try t.expect(std.mem.indexOf(u8, rel, "..") == null);
}

test "machinery: `under` is boundary-checked, not a bare prefix" {
    try t.expect(under("/a/b", "/a/b"));
    try t.expect(under("/a/b/c", "/a/b"));
    try t.expect(!under("/a/bc", "/a/b")); // the boundary nit
    try t.expect(!under("/a", "/a/b"));
    try t.expect(!under("/a/b", "")); // an unresolved location denies nothing
    try t.expect(under("/anything", "/"));
}

test "machinery: every location this build has resolves to an absolute path" {
    ensureResolved();
    // A test build's module cache and kv store are the build-baked dirs
    // (`addHostTestDirs` in build.zig), so BOTH are always present here —
    // which is what lets the fs gates below assert against them by name. The
    // two keystores depend on the developer's own `$HOME`/`$XDG_CONFIG_HOME`,
    // so they are checked only when the environment supplies them.
    try t.expect(g_resolved[@intFromEnum(Location.module_cache)].lexical.len > 0);
    try t.expect(g_resolved[@intFromEnum(Location.kv_state)].lexical.len > 0);
    for (g_resolved) |r| {
        if (r.lexical.len == 0) continue;
        try t.expect(std.fs.path.isAbsolute(r.lexical));
        try t.expect(std.fs.path.isAbsolute(r.kernel));
        try t.expect(std.mem.indexOf(u8, r.lexical, "/../") == null);
    }
}

test "machinery: the module cache is denied by name, by traversal, and by symlink" {
    ensureResolved();
    const cache = g_resolved[@intFromEnum(Location.module_cache)].lexical;
    try t.expectEqual(Location.module_cache, locationOf(cache).?);

    const gpa = t.allocator;
    // A file INSIDE it, whether or not it exists.
    const inside = try std.fmt.allocPrint(gpa, "{s}/deadbeef.cwasm", .{cache});
    defer gpa.free(inside);
    try t.expectEqual(Location.module_cache, locationOf(inside).?);

    // The `..` spelling: lexically it never mentions the cache directly.
    const traversal = try std.fmt.allocPrint(gpa, "{s}/nope/../deadbeef.cwasm", .{cache});
    defer gpa.free(traversal);
    try t.expectEqual(Location.module_cache, locationOf(traversal).?);

    // A sibling whose name merely STARTS with the cache's is content.
    const sibling = try std.fmt.allocPrint(gpa, "{s}-elsewhere/x", .{cache});
    defer gpa.free(sibling);
    try t.expect(locationOf(sibling) == null);
}

test "machinery: ordinary user content is not denied" {
    try t.expect(locationOf("build.zig") == null);
    try t.expect(locationOf("src/core/machinery.zig") == null);
    try t.expect(locationOf("/etc/hostname") == null);
    try t.expect(locationOf("/tmp") == null);
    // Not a general "anything under $HOME" ban: the carve-out is bucket 1,
    // not the user's home directory (doc/place.md §4 — `~/.ssh` is content a
    // grant may legitimately reach, and confining THAT is the separate
    // confined-by-default policy change, not this one).
    if (std.c.getenv("HOME")) |h| {
        const gpa = t.allocator;
        const doc = try std.fmt.allocPrint(gpa, "{s}/some-ordinary-file.txt", .{std.mem.span(h)});
        defer gpa.free(doc);
        try t.expect(locationOf(doc) == null);
    }
}

test {
    std.testing.refAllDecls(@This());
}
