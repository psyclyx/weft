//! `kv_file` — the DISK half of `kv.zig`, and the reason that module's
//! header can say plugin state "outlives a run" without lying.
//!
//! `kv.zig` stays pure on purpose (see its own doc): it flattens a store
//! into a self-describing blob and rebuilds one from such a blob, and does
//! no I/O at all. That leaves exactly one thing unowned — *who writes the
//! blob, where, and when*. This file is that owner, kept separate so the
//! store itself remains trivially testable with no filesystem in sight.
//!
//! **What is persisted: the PLUGIN kv store only.** `System.Plugins.kv`
//! (matcher frecency, recent/kill/mark rings, `project-recent`) is state a
//! plugin authored at runtime and nothing else can reproduce, so losing it
//! at exit loses information. `System.config_kv` is deliberately NOT
//! persisted: config values come from the config script on every run and
//! the config script is the source of truth, so a persisted blob could only
//! ever shadow an edited config with a stale value. See `Binding.open`'s
//! call site for the same note where the choice is actually made.
//!
//! **Where.** Editor machinery, so XDG, resolved host-side (`stateDir`).
//! **Failure is never fatal.** A missing file is a fresh store, a corrupt
//! one is a warning and a fresh store, and a failed write costs the state,
//! never the exit — every entry point here returns `void` so there is no
//! error for a caller to mishandle in the first place.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const kv = @import("kv.zig");
const file = @import("file.zig");

/// The blob's name inside `stateDir()`. `stateDir` names a DIRECTORY rather
/// than this file directly so that a second persisted store, should one ever
/// exist, is one more name here — not a second path-resolution scheme.
pub const store_file = "plugins.kv";

/// Where the plugin kv store is persisted. Mirrors `wasm.zig`'s
/// `Engine.cacheDir` exactly, carve-out included: in a TEST BUILD the path
/// comes from the build-baked `kv_state_options.test_dir` (under the project
/// cache root) and the user-environment branch below is comptime-pruned, so
/// a bare-run test binary provably cannot touch the user's real kv.
/// Production resolves `$WEFT_STATE_DIR`, else `$XDG_STATE_HOME/weft/kv`,
/// else `$HOME/.local/state/weft/kv`. Null = persistence off; the editor
/// still runs, plugin state just doesn't survive the process. Caller owns
/// the result.
pub fn stateDir(gpa: Allocator) ?[]u8 {
    if (builtin.is_test)
        return gpa.dupe(u8, @import("kv_state_options").test_dir) catch null;
    if (std.c.getenv("WEFT_STATE_DIR")) |d| return gpa.dupe(u8, std.mem.span(d)) catch null;
    if (std.c.getenv("XDG_STATE_HOME")) |d|
        return std.fs.path.join(gpa, &.{ std.mem.span(d), "weft", "kv" }) catch null;
    if (std.c.getenv("HOME")) |d|
        return std.fs.path.join(gpa, &.{ std.mem.span(d), ".local", "state", "weft", "kv" }) catch null;
    return null;
}

/// Replace `store`'s contents with what `dir` holds. A STARTUP operation:
/// `kv.Store.load` replaces wholesale, so anything already in `store` is
/// dropped. Degrades in three steps, none of them fatal:
///
///   - no file (first run, or persistence off) → a fresh store, silently;
///     an absent file is the expected state, not a fault.
///   - unreadable file → warned, fresh store.
///   - corrupt/truncated blob → warned, fresh store. `kv.Store.load`
///     already leaves the store empty-and-usable on `error.Corrupt`, so
///     "recover by starting over" needs no cleanup here.
pub fn loadFrom(gpa: Allocator, store: *kv.Store, dir: []const u8) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, store_file }) catch return;
    const bytes = file.readAlloc(gpa, path) catch |e| switch (e) {
        error.FileNotFound => return, // first run: nothing to restore
        else => {
            std.log.warn("kv: {s} unreadable ({t}) — starting with an empty store", .{ path, e });
            return;
        },
    };
    defer gpa.free(bytes);
    store.load(gpa, bytes) catch |e| {
        std.log.warn("kv: {s} is not a store we wrote ({t}) — starting with an empty store", .{ path, e });
    };
}

/// Flatten `store` into `dir` (created if missing). Best-effort by
/// construction: a failed serialize or write is warned and dropped, because
/// a shutdown that cannot save its scratch state must still be a clean
/// shutdown. The write goes through `writeBytesMakingDirs`, so a reader only
/// ever sees a whole blob — a half-written file is not a state this can
/// leave behind.
pub fn saveTo(gpa: Allocator, store: *const kv.Store, dir: []const u8) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, store_file }) catch return;
    const blob = store.serialize(gpa) catch |e| {
        std.log.warn("kv: could not serialize the plugin store ({t}) — state not saved", .{e});
        return;
    };
    defer gpa.free(blob);
    file.writeBytesMakingDirs(gpa, dir, path, blob) catch |e| {
        std.log.warn("kv: could not write {s} ({t}) — state not saved", .{ path, e });
    };
}

/// A store bound to its file for the life of a run. `open` LOADS, `close`
/// SAVES — one handle arming both halves, so an embedder cannot restore
/// plugin state without also arming its write-back, and cannot arrange to
/// save state it never restored. (The pairing is why this is a handle and
/// not two free functions at the entry point: `open` allocates the resolved
/// directory, so an unpaired `open` is a leak a debug build reports, rather
/// than a silently-dropped save nobody notices until the next launch.)
///
/// Deliberately NOT wired into `System.Plugins.init`/`deinit`, tempting as
/// that is: a test build's `stateDir` is one shared build-baked directory,
/// so auto-persisting on every `System` teardown would make any two tests
/// that stand up plugins share mutable state and run order-dependently.
/// Persistence is a property of the editor PROCESS, so the process arms it.
pub const Binding = struct {
    gpa: Allocator,
    store: *kv.Store,
    /// Resolved once, at `open`. Null = persistence off (no writable base);
    /// both halves then degenerate to no-ops and the editor runs unchanged.
    dir: ?[]u8,

    pub fn open(gpa: Allocator, store: *kv.Store) Binding {
        return openIn(gpa, store, stateDir(gpa));
    }

    /// `open` with the directory handed in rather than resolved — takes
    /// ownership of `dir` (freed by `close`), null meaning persistence off.
    /// `open` is exactly this composed with `stateDir`, which is what lets
    /// a test pin a private directory and still exercise every byte of the
    /// production path; `open`'s only extra job, resolving `stateDir`, is
    /// gated separately (see the state-dir test below).
    pub fn openIn(gpa: Allocator, store: *kv.Store, dir: ?[]u8) Binding {
        if (dir) |d| loadFrom(gpa, store, d);
        return .{ .gpa = gpa, .store = store, .dir = dir };
    }

    pub fn close(self: *Binding) void {
        if (self.dir) |d| {
            saveTo(self.gpa, self.store, d);
            self.gpa.free(d);
        }
        self.* = undefined;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

/// A private directory under the build-baked test root. Absolute (so the
/// e2e harness's mid-suite chdir cannot strand it) and pid-tagged (the same
/// test source is linked into more than one test binary — `test_mod` and
/// `weft_mod` — which the runner may execute concurrently). Pair with
/// `removeTestDir` so a green run leaves the cache as it found it.
fn testDir(gpa: Allocator, name: []const u8) ![]u8 {
    const base = stateDir(gpa).?;
    defer gpa.free(base);
    return std.fmt.allocPrint(gpa, "{s}/t-{s}-{d}", .{ base, name, std.os.linux.getpid() });
}

/// Drop a `testDir` once its contents are gone. Best-effort: a directory
/// that never got created, or one a sibling still holds, is not a failure.
fn removeTestDir(gpa: Allocator, dir: []const u8) void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().deleteDir(threaded.io(), dir) catch {};
}

test "kv_file: a test build's state dir is the build-baked directory" {
    const dir = stateDir(t.allocator).?;
    defer t.allocator.free(dir);
    try t.expectEqualStrings(@import("kv_state_options").test_dir, dir);
    try t.expect(std.fs.path.isAbsolute(dir));
}

test "kv_file: save→load through the real file path preserves entries" {
    const gpa = t.allocator;
    const dir = try testDir(gpa, "roundtrip");
    defer gpa.free(dir);
    defer removeTestDir(gpa, dir); // LIFO: runs after the file below is gone
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, store_file });
    defer gpa.free(path);
    file.deleteFile(gpa, path);
    defer file.deleteFile(gpa, path);

    var store: kv.Store = .empty;
    defer store.deinit(gpa);
    try store.put(gpa, "project", "recent", "a.zig\nb.zig");
    try store.put(gpa, "project", "root", "/tmp/proj");
    try store.put(gpa, "matcher", "frecency", "\x00\x01\xff"); // arbitrary bytes
    try store.put(gpa, "ring", "kill", ""); // zero-length value survives
    saveTo(gpa, &store, dir);

    // A real file landed at the real path — this is the disk hop the pure
    // serialize→load unit tests deliberately do not make.
    try t.expectEqual(file.Kind.file, file.statKind(gpa, path));

    var restored: kv.Store = .empty;
    defer restored.deinit(gpa);
    loadFrom(gpa, &restored, dir);
    try t.expectEqualStrings("a.zig\nb.zig", restored.get("project", "recent").?);
    try t.expectEqualStrings("/tmp/proj", restored.get("project", "root").?);
    try t.expectEqualStrings("\x00\x01\xff", restored.get("matcher", "frecency").?);
    try t.expectEqualStrings("", restored.get("ring", "kill").?);
    // Namespaces still isolate after the disk hop.
    try t.expectEqual(@as(?[]const u8, null), restored.get("matcher", "recent"));
}

test "kv_file: a corrupt blob yields an empty, usable store and does not error" {
    const gpa = t.allocator;
    const dir = try testDir(gpa, "corrupt");
    defer gpa.free(dir);
    defer removeTestDir(gpa, dir); // LIFO: runs after the file below is gone
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, store_file });
    defer gpa.free(path);
    defer file.deleteFile(gpa, path);

    // Not a blob we wrote: a plausible-looking length prefix over-running a
    // truncated body — the shape a half-written or foreign file would take.
    try file.writeBytesMakingDirs(gpa, dir, path, "\x01\x40not-a-store");

    var store: kv.Store = .empty;
    defer store.deinit(gpa);
    loadFrom(gpa, &store, dir); // returns void: there is no error to propagate
    try t.expectEqual(@as(usize, 0), store.ns.count());

    // Empty is not broken — the store is usable, so the run continues and
    // the next clean shutdown simply overwrites the bad file.
    try store.put(gpa, "project", "recent", "fresh.zig");
    try t.expectEqualStrings("fresh.zig", store.get("project", "recent").?);
}

test "kv_file: a missing file is a fresh store, silently" {
    const gpa = t.allocator;
    const dir = try testDir(gpa, "absent");
    defer gpa.free(dir);
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, store_file });
    defer gpa.free(path);
    file.deleteFile(gpa, path);

    var store: kv.Store = .empty;
    defer store.deinit(gpa);
    loadFrom(gpa, &store, dir);
    try t.expectEqual(@as(usize, 0), store.ns.count());
}

test "kv_file: a Binding's close is the save its open is the load" {
    const gpa = t.allocator;
    const dir = try testDir(gpa, "binding");
    defer gpa.free(dir);
    defer removeTestDir(gpa, dir); // LIFO: runs after the file below is gone
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, store_file });
    defer gpa.free(path);
    file.deleteFile(gpa, path);
    defer file.deleteFile(gpa, path);

    {
        var store: kv.Store = .empty;
        defer store.deinit(gpa);
        // First "run": nothing to restore, and nothing on disk yet.
        var binding = Binding.openIn(gpa, &store, try gpa.dupe(u8, dir));
        defer binding.close();
        try t.expectEqual(@as(usize, 0), store.ns.count());
        try store.put(gpa, "project", "recent", "survivor.zig");
    } // close() saved here

    // A SECOND "run" over the same directory sees the first one's state —
    // the whole point: the store outlives the process that wrote it. This is
    // exactly what `project-recent` silently lost on every restart.
    var next: kv.Store = .empty;
    defer next.deinit(gpa);
    var binding = Binding.openIn(gpa, &next, try gpa.dupe(u8, dir));
    defer binding.close();
    try t.expectEqualStrings("survivor.zig", next.get("project", "recent").?);
}

test "kv_file: persistence off (no writable base) is a working, non-persisting store" {
    const gpa = t.allocator;
    var store: kv.Store = .empty;
    defer store.deinit(gpa);
    var binding = Binding.openIn(gpa, &store, null);
    defer binding.close(); // saves nowhere, frees nothing, must not fault
    try store.put(gpa, "project", "recent", "ephemeral.zig");
    try t.expectEqualStrings("ephemeral.zig", store.get("project", "recent").?);
}

test {
    std.testing.refAllDecls(@This());
}
