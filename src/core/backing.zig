//! Backing — where a buffer's bytes live, and the sync discipline that
//! makes concurrent editors of the same file safe (design rev 4: the
//! backing file IS a peer).
//!
//! `Backing` is the three-case authority: a local path, a remote path
//! on another tier (a shell's coreutils, a peer's shared tree — one `Remote`
//! seam), or nothing (scratch — including a projection
//! whose bytes a plugin peer regenerates, named by the entry's `tool`).
//! `Sync` is the engine shared by the two file-shaped cases: a Document
//! peer whose replica always mirrors the last-known disk content.
//!
//! The invariants:
//! - The mirror replica's text equals the disk content identified by
//!   `token` (an opaque content token — `ShellFs.hashToken` remotely,
//!   sha256 locally).
//! - The mirror is NEVER pulled to head (`peerSnapshot` is off-limits):
//!   an external disk change is diffed against the mirror and committed
//!   as the mirror's own ops, so the CRDT transforms it against unsaved
//!   local work — nvim's `:w` merges like a remote collaborator.
//! - A save writes the buffer at a version `Vs` with a *guarded*
//!   test-and-set (only if the disk still matches `token`); on success
//!   the mirror advances to exactly `Vs` (`peerSyncTo` — not head,
//!   which may already contain post-save typing). On `error.Stale`,
//!   merge the disk first, then retry.
//!
//! The diff is `textdiff.diffWindow` — prefix/suffix trimming, one
//! replaced window. Correct always (both sides converge on the disk
//! content); coarser than a structural diff when an external writer edits
//! two distant regions (the window spans both). A refinement ladder
//! (line-based Myers inside the window) exists if that coarseness ever
//! bites; anchors inside the replaced window collapse to its edge either
//! way. `transcript.zig`'s `on_save` row reconciliation needs the
//! identical "old vs new → one window" shape, so the diff itself lives in
//! `textdiff.zig`, shared — see that file's module doc comment.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const stemma = @import("stemma");
const Document = @import("Document.zig");
const ShellFs = @import("ShellFs.zig");
const textdiff = @import("textdiff.zig");

/// Where a buffer's bytes live. The authority, not just a path.
pub const Backing = union(enum) {
    /// Scratch: no authority, no save.
    none,
    /// A local file (task-pool atomic writes).
    file: struct { path: []u8, sync: Sync },
    /// A file somewhere else — over a shell's coreutils (`ShellRemote`), in a
    /// peer's shared tree — reached through its tier's `Remote`. One guarded
    /// save and one external-change merge for every tier: what differs is
    /// only how bytes and tokens cross, never the discipline around them.
    remote: struct { remote: Remote, sync: Sync },
};

/// The bytes a fetch brought back and the content token they carry.
pub const Fetched = @import("file.zig").Fetched;

/// How a remote tier fails. `Stale` is the guard (merge, then retry);
/// `Unreachable` the transport; `NotPermitted` the far side's refusal to be
/// written (a peer that granted no write surface).
pub const RemoteError = error{ Stale, Unreachable, NotPermitted, Failed, OutOfMemory };

/// A file on another tier: the two operations the backing peer needs,
/// behind one seam. `fetch` answers the bytes and token iff the token moved
/// from `expected` (null: unconditionally — the open); `write` is the
/// guarded test-and-set of substrate §2 (upload beside, move iff the target
/// still has `expected`'s content — null: iff there is none — else `Stale`)
/// and answers the written content's token. Tokens are opaque, compared for
/// equality only, and each tier's own.
pub const Remote = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Where the tier's calls may run. A shell channel serializes itself and
    /// may be driven from a pool worker; a peer's tree rides the connection
    /// the frame thread ticks, so its calls run on the thread that asked.
    pub const Affinity = enum { worker, caller };

    pub const VTable = struct {
        /// Status-chip word for the tier ("shell", "peer").
        label: []const u8,
        affinity: Affinity,
        /// The path on the far side, for display. Borrowed.
        path: *const fn (ctx: *anyopaque) []const u8,
        fetch: *const fn (ctx: *anyopaque, gpa: Allocator, expected: ?[]const u8) RemoteError!?Fetched,
        write: *const fn (ctx: *anyopaque, gpa: Allocator, bytes: []const u8, expected: ?[]const u8) RemoteError![]u8,
        /// Free the tier's state; the backing is going.
        deinit: *const fn (ctx: *anyopaque, gpa: Allocator) void,
    };

    pub fn path(self: Remote) []const u8 {
        return self.vtable.path(self.ctx);
    }
    pub fn fetch(self: Remote, gpa: Allocator, expected: ?[]const u8) RemoteError!?Fetched {
        return self.vtable.fetch(self.ctx, gpa, expected);
    }
    pub fn write(self: Remote, gpa: Allocator, bytes: []const u8, expected: ?[]const u8) RemoteError![]u8 {
        return self.vtable.write(self.ctx, gpa, bytes, expected);
    }
    pub fn deinit(self: Remote, gpa: Allocator) void {
        self.vtable.deinit(self.ctx, gpa);
    }
};

/// The coreutils tier as a `Remote`: a path over a persistent shell.
pub const ShellRemote = struct {
    fs: *ShellFs,
    path: []u8,

    pub fn create(gpa: Allocator, fs: *ShellFs, remote_path: []const u8) Allocator.Error!Remote {
        const self = try gpa.create(ShellRemote);
        errdefer gpa.destroy(self);
        self.* = .{ .fs = fs, .path = try gpa.dupe(u8, remote_path) };
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// The shell file behind `remote`, if it is one.
    pub fn of(remote: Remote) ?*ShellRemote {
        return if (remote.vtable == &vtable) @ptrCast(@alignCast(remote.ctx)) else null;
    }

    const vtable: Remote.VTable = .{
        .label = "shell",
        .affinity = .worker,
        .path = pathOf,
        .fetch = fetchShell,
        .write = writeShell,
        .deinit = deinitShell,
    };

    fn cast(ctx: *anyopaque) *ShellRemote {
        return @ptrCast(@alignCast(ctx));
    }

    fn pathOf(ctx: *anyopaque) []const u8 {
        return cast(ctx).path;
    }

    fn mapError(err: ShellFs.WriteError) RemoteError {
        return switch (err) {
            error.Stale => error.Stale,
            error.Shell => error.Unreachable,
            error.Failed => error.Failed,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn fetchShell(ctx: *anyopaque, gpa: Allocator, expected: ?[]const u8) RemoteError!?Fetched {
        const self = cast(ctx);
        const token = self.fs.hashToken(gpa, self.path) catch |err| return mapError(err);
        if (expected) |e| if (std.mem.eql(u8, token, e)) {
            gpa.free(token);
            return null;
        };
        errdefer gpa.free(token);
        const bytes = self.fs.readAll(gpa, self.path) catch |err| return mapError(err);
        return .{ .bytes = bytes, .token = token };
    }

    fn writeShell(ctx: *anyopaque, gpa: Allocator, bytes: []const u8, expected: ?[]const u8) RemoteError![]u8 {
        const self = cast(ctx);
        return self.fs.writeGuarded(gpa, self.path, bytes, expected) catch |err| mapError(err);
    }

    fn deinitShell(ctx: *anyopaque, gpa: Allocator) void {
        const self = cast(ctx);
        gpa.free(self.path);
        gpa.destroy(self);
    }
};

/// The backing peer: mirror of the last-known disk content.
pub const Sync = struct {
    peer: Document.PeerId,
    /// Opaque content token of the disk state the mirror reflects
    /// (null until the first load/save). Compared for equality only.
    token: ?[]u8 = null,

    pub const peer_name = "backing.fs";

    pub fn init(gpa: Allocator, doc: *Document) Document.AddPeerError!Sync {
        return .{ .peer = try doc.addPeer(gpa, peer_name) };
    }

    pub fn deinit(self: *Sync, gpa: Allocator, doc: *Document) void {
        if (self.token) |tk| gpa.free(tk);
        doc.removePeer(gpa, self.peer);
        self.* = undefined;
    }

    /// Initial load into an empty document: the disk content arrives as
    /// the mirror's insert (a mutation by the filesystem, not the user —
    /// not undoable), and the mirror is exactly the disk.
    pub fn load(self: *Sync, gpa: Allocator, doc: *Document, bytes: []const u8, token: []const u8) Allocator.Error!void {
        assert(doc.peerText(self.peer).isEmpty());
        if (bytes.len > 0) {
            try doc.peerInsert(gpa, self.peer, 0, bytes);
            _ = try doc.peerCommit(gpa, self.peer);
        }
        try self.setToken(gpa, token);
    }

    /// Adopt an already base-loaded document (bulk load: the content IS
    /// the compacted base, zero events — see `Document.adoptContent`).
    /// The mirror peer bootstraps from the base, so it equals the disk
    /// without any insert.
    pub fn loadBased(self: *Sync, gpa: Allocator, doc: *Document, token: []const u8) Allocator.Error!void {
        assert(doc.peerText(self.peer).eql(doc.text().*));
        try self.setToken(gpa, token);
    }

    /// An external writer changed the disk: commit the difference as
    /// the mirror's ops (merges into the buffer like a remote
    /// collaborator's edits) and adopt the new token. Returns whether
    /// the buffer changed.
    pub fn mergeExternal(self: *Sync, gpa: Allocator, doc: *Document, new_bytes: []const u8, token: []const u8) Allocator.Error!bool {
        const mirror = doc.peerText(self.peer);
        const old_bytes = try ropeBytes(gpa, mirror);
        defer gpa.free(old_bytes);
        const changed = if (textdiff.diffWindow(old_bytes, new_bytes)) |w| blk: {
            if (w.old_end > w.start) {
                try doc.peerDelete(gpa, self.peer, .{ .start = w.start, .end = w.old_end });
            }
            if (w.new_end > w.start) {
                try doc.peerInsert(gpa, self.peer, w.start, new_bytes[w.start..w.new_end]);
            }
            break :blk try doc.peerCommit(gpa, self.peer);
        } else false;
        try self.setToken(gpa, token);
        return changed;
    }

    /// A guarded save of version `saved_version` landed: the disk now
    /// holds exactly that version's content. Advance the mirror to it —
    /// not to head, which may already contain post-save typing.
    pub fn markSaved(self: *Sync, gpa: Allocator, doc: *Document, saved_version: []const u8, token: []const u8) Allocator.Error!void {
        try doc.peerSyncTo(gpa, self.peer, saved_version);
        try self.setToken(gpa, token);
    }

    fn setToken(self: *Sync, gpa: Allocator, token: []const u8) Allocator.Error!void {
        const dup = try gpa.dupe(u8, token);
        if (self.token) |old| gpa.free(old);
        self.token = dup;
    }
};

/// Content token for local files: sha256 hex — same equality-only
/// contract as `ShellFs.hashToken`, computed on bytes we already hold.
pub fn localToken(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        _ = std.fmt.bufPrint(hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
    }
    return hex;
}

fn ropeBytes(gpa: Allocator, rope: *const stemma.Rope) Allocator.Error![]u8 {
    var snap = rope.snapshot();
    defer snap.deinit(gpa);
    return snap.toOwnedSlice(gpa);
}

// ── Tests ───────────────────────────────────────────────────────────
// The concurrency scenarios from design rev 4, end to end through a
// real file and a real /bin/sh: weft + external writer (the nvim
// case), and two unconnected wefts converging through the disk.

const t = std.testing;

fn shellEnviron() std.process.Environ {
    return .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

fn docBytes(gpa: Allocator, doc: *const Document) ![]u8 {
    return ropeBytes(gpa, doc.text());
}

test "backing: external write merges with unsaved local edits (the nvim case)" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var sync = try Sync.init(gpa, &doc);
    defer sync.deinit(gpa, &doc);

    const disk0 = "line one\nline two\nline three\n";
    const tk0 = localToken(disk0);
    try sync.load(gpa, &doc, disk0, &tk0);

    // Local unsaved edit at the top…
    try doc.insert(gpa, 0, "LOCAL ");
    // …while "nvim" rewrites line three on disk.
    const disk1 = "line one\nline two\nline 3!\n";
    const tk1 = localToken(disk1);
    try t.expect(try sync.mergeExternal(gpa, &doc, disk1, &tk1));

    const merged = try docBytes(gpa, &doc);
    defer gpa.free(merged);
    try t.expectEqualStrings("LOCAL line one\nline two\nline 3!\n", merged);

    // A second identical poll is a no-op.
    try t.expect(!try sync.mergeExternal(gpa, &doc, disk1, &tk1));
}

test "backing: save advances the mirror to the saved version, not head" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var sync = try Sync.init(gpa, &doc);
    defer sync.deinit(gpa, &doc);
    const tk0 = localToken("base");
    try sync.load(gpa, &doc, "base", &tk0);

    try doc.insert(gpa, 4, " saved");
    const saved_version = try doc.version(gpa);
    defer gpa.free(saved_version);
    const saved_bytes = try docBytes(gpa, &doc);
    defer gpa.free(saved_bytes);
    // Post-save typing lands before the save completes.
    try doc.insert(gpa, 0, "unsaved ");

    const tk1 = localToken(saved_bytes);
    try sync.markSaved(gpa, &doc, saved_version, &tk1);
    // Mirror == what the disk holds (the saved version), not the head.
    const mirror = try ropeBytes(gpa, doc.peerText(sync.peer));
    defer gpa.free(mirror);
    try t.expectEqualStrings("base saved", mirror);

    // The next external change diffs against the *saved* state, so our
    // own saved edits are not re-imported as someone else's.
    const disk2 = "base saved externally\n";
    const tk2 = localToken(disk2);
    _ = try sync.mergeExternal(gpa, &doc, disk2, &tk2);
    const merged = try docBytes(gpa, &doc);
    defer gpa.free(merged);
    try t.expectEqualStrings("unsaved base saved externally\n", merged);
}

test "backing: two unconnected editors converge through one file over /bin/sh" {
    const gpa = t.allocator;
    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/shared.txt", .{tmp_dir.sub_path});
    defer gpa.free(path);

    var fs = try ShellFs.spawn(gpa, &.{"/bin/sh"}, shellEnviron());
    defer fs.deinit();

    // Editor A creates the file.
    var a = try Document.init(gpa, "alice");
    defer a.deinit(gpa);
    var sa = try Sync.init(gpa, &a);
    defer sa.deinit(gpa, &a);
    try a.insert(gpa, 0, "alpha\nomega\n");
    {
        const av = try a.version(gpa);
        defer gpa.free(av);
        const bytes = try docBytes(gpa, &a);
        defer gpa.free(bytes);
        const tk = try fs.writeGuarded(gpa, path, bytes, null);
        defer gpa.free(tk);
        try sa.markSaved(gpa, &a, av, tk);
    }

    // Editor B opens the same file (no wire between A and B).
    var b = try Document.init(gpa, "bob");
    defer b.deinit(gpa);
    var sb = try Sync.init(gpa, &b);
    defer sb.deinit(gpa, &b);
    {
        const bytes = try fs.readAll(gpa, path);
        defer gpa.free(bytes);
        const tk = try fs.hashToken(gpa, path);
        defer gpa.free(tk);
        try sb.load(gpa, &b, bytes, tk);
    }

    // Both edit different regions; A saves first.
    try a.insert(gpa, 0, "A: ");
    try b.insert(gpa, b.text().byteLen(), "B was here\n");
    {
        const av = try a.version(gpa);
        defer gpa.free(av);
        const bytes = try docBytes(gpa, &a);
        defer gpa.free(bytes);
        const tk = try fs.writeGuarded(gpa, path, bytes, sa.token.?);
        defer gpa.free(tk);
        try sa.markSaved(gpa, &a, av, tk);
    }

    // B's guarded save is stale — merge the disk, then retry: nothing lost.
    {
        const bv = try b.version(gpa);
        defer gpa.free(bv);
        const bytes = try docBytes(gpa, &b);
        defer gpa.free(bytes);
        try t.expectError(error.Stale, fs.writeGuarded(gpa, path, bytes, sb.token.?));

        const disk = try fs.readAll(gpa, path);
        defer gpa.free(disk);
        const tk = try fs.hashToken(gpa, path);
        defer gpa.free(tk);
        _ = try sb.mergeExternal(gpa, &b, disk, tk);
        const merged = try docBytes(gpa, &b);
        defer gpa.free(merged);
        const bv2 = try b.version(gpa);
        defer gpa.free(bv2);
        const tk2 = try fs.writeGuarded(gpa, path, merged, sb.token.?);
        defer gpa.free(tk2);
        try sb.markSaved(gpa, &b, bv2, tk2);
    }

    // A polls, merges B's save: both editors and the disk agree, and
    // both editors' contributions survived.
    {
        const disk = try fs.readAll(gpa, path);
        defer gpa.free(disk);
        const tk = try fs.hashToken(gpa, path);
        defer gpa.free(tk);
        _ = try sa.mergeExternal(gpa, &a, disk, tk);
        const a_text = try docBytes(gpa, &a);
        defer gpa.free(a_text);
        const b_text = try docBytes(gpa, &b);
        defer gpa.free(b_text);
        try t.expectEqualStrings(b_text, a_text);
        try t.expect(std.mem.indexOf(u8, a_text, "A: ") != null);
        try t.expect(std.mem.indexOf(u8, a_text, "B was here") != null);
    }
}
