//! ShellProvider — the coreutils tier (`ShellFs`) as a filesystem provider:
//! the same `weft_fs.service.Provider` contract a local tree and a peer's
//! shared tree answer, so a `shell:` place lists, publishes children, and
//! opens its rows through exactly the machinery every other directory does
//! (the files listing, `publishChildByName`, a sidebar following the place,
//! a reveal). Nothing above this file knows the far side is a shell.
//!
//! What the tier can honestly offer, and no more:
//!
//! - **Names are paths.** A root is an absolute path on the far side; an
//!   entry is a path below one. Handles are interned per path, so listing a
//!   directory twice names its children with the same refs.
//! - **Revisions are `ls -l` stamps** (mode, links, owner, group, size,
//!   date), whitespace-normalized so a listing's line and a lone `ls -ld`
//!   agree. That is substrate §2's mtime+size fallback with its known cost:
//!   `ls` dates are minute-grained, so two same-size writes inside a minute
//!   read as one revision. Content identity is the file backing's business
//!   (`ShellFs.hashToken`, sha256 where the host has it), not the listing's.
//! - **Reads and listings only.** Every capability is off and `apply`,
//!   `capture` and `watch` refuse as unsupported: a listing over a shell is
//!   browsable, and its files open and save through their own guarded
//!   backing, but its tree is not edited through a draft here.
//!
//! Every call is a round trip on the calling thread — the channel's own
//! mutex serializes it against backing workers — and the channel reports
//! how it is doing (`ShellFs.liveness`); a dead shell surfaces as `Io`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fs = @import("weft_fs");
const semantic = @import("weft_semantic");
const ShellFs = @import("ShellFs.zig");

const contract = fs.contract;
const ShellProvider = @This();

gpa: Allocator,
channel: *ShellFs,
authority: semantic.handle.Authority,
/// Slot → the absolute path a root names. Never reused, so a released
/// root's handle cannot come to mean another directory.
roots: std.ArrayList([]u8) = .empty,
/// Slot → the absolute path an entry names, interned by `entry_slots`.
entries: std.ArrayList([]u8) = .empty,
entry_slots: std.StringHashMapUnmanaged(u32) = .empty,

const generation: u32 = 1;

pub fn init(gpa: Allocator, channel: *ShellFs, authority: semantic.handle.Authority) ShellProvider {
    return .{ .gpa = gpa, .channel = channel, .authority = authority };
}

pub fn deinit(self: *ShellProvider) void {
    for (self.roots.items) |p| self.gpa.free(p);
    self.roots.deinit(self.gpa);
    for (self.entries.items) |p| self.gpa.free(p);
    self.entries.deinit(self.gpa);
    self.entry_slots.deinit(self.gpa);
    self.* = undefined;
}

pub fn provider(self: *ShellProvider) fs.service.Provider {
    return .init(self);
}

/// A root naming the directory at absolute `path` on the far side. Nothing
/// is asked of the far side here: whoever binds the root observes it.
pub fn acquireRoot(self: *ShellProvider, path: []const u8) Allocator.Error!contract.Root {
    const owned = try self.gpa.dupe(u8, trimSlash(path));
    errdefer self.gpa.free(owned);
    try self.roots.append(self.gpa, owned);
    return .{ .authority = self.authority, .slot = @intCast(self.roots.items.len - 1), .generation = generation };
}

fn trimSlash(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    return if (trimmed.len == 0) "/" else trimmed;
}

fn rootPath(self: *const ShellProvider, root: contract.Root) contract.Error![]const u8 {
    if (root.authority != self.authority or root.generation != generation or root.slot >= self.roots.items.len)
        return error.Stale;
    return self.roots.items[root.slot];
}

fn entryPath(self: *const ShellProvider, ref: contract.EntryRef) contract.Error![]const u8 {
    if (ref.authority != self.authority or ref.generation != generation or ref.slot >= self.entries.items.len)
        return error.Stale;
    return self.entries.items[ref.slot];
}

/// Whether `path` is `base` or below it — the confinement a root promises.
fn beneath(base: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, base, "/")) return true;
    return std.mem.eql(u8, base, path) or
        (path.len > base.len and std.mem.startsWith(u8, path, base) and path[base.len] == '/');
}

fn nodePath(self: *const ShellProvider, root: contract.Root, node: contract.NodeRef) contract.Error![]const u8 {
    const base = try self.rootPath(root);
    return switch (node) {
        .root => base,
        .entry => |ref| blk: {
            const path = try self.entryPath(ref);
            if (!beneath(base, path)) return error.Confined;
            break :blk path;
        },
    };
}

fn intern(self: *ShellProvider, dir: []const u8, name: []const u8) contract.Error!contract.EntryRef {
    const path = if (std.mem.eql(u8, dir, "/"))
        try std.fmt.allocPrint(self.gpa, "/{s}", .{name})
    else
        try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ dir, name });
    if (self.entry_slots.get(path)) |slot| {
        self.gpa.free(path);
        return .{ .authority = self.authority, .slot = slot, .generation = generation };
    }
    errdefer self.gpa.free(path);
    const slot: u32 = @intCast(self.entries.items.len);
    try self.entries.append(self.gpa, path);
    errdefer _ = self.entries.pop();
    try self.entry_slots.put(self.gpa, path, slot);
    return .{ .authority = self.authority, .slot = slot, .generation = generation };
}

fn mapError(err: ShellFs.Error) contract.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Failed => error.NotFound,
        error.Shell => error.Io,
    };
}

fn kindOf(kind: ShellFs.Kind) contract.Kind {
    return switch (kind) {
        .file => .regular,
        .dir => .directory,
        .link => .symlink,
        .other => .other,
    };
}

/// A stamp with its column padding folded to single spaces, so the same
/// file reads the same from `ls -la` of its directory and `ls -ld` of it.
fn normalize(arena: Allocator, stamp: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, stamp, " \t");
    while (words.next()) |word| {
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, word);
    }
    return out.toOwnedSlice(arena);
}

fn observation(arena: Allocator, node: contract.NodeRef, e: ShellFs.Entry) Allocator.Error!contract.Observation {
    return .{
        .node = node,
        .revision = .{ .token = try normalize(arena, e.stamp) },
        .kind = kindOf(e.kind),
        .metadata = .{ .size = e.size },
    };
}

/// What is at `path` now, into `arena`; `NotFound` when nothing is.
fn observePath(self: *ShellProvider, arena: Allocator, node: contract.NodeRef, path: []const u8) contract.Error!contract.Observation {
    const found = (self.channel.stat(self.gpa, path) catch |err| return mapError(err)) orelse return error.NotFound;
    defer self.gpa.free(found.bytes);
    return observation(arena, node, found.entry);
}

// ── fs.service.Provider ─────────────────────────────────────────────

pub fn capabilities(self: *ShellProvider, root: contract.Root) contract.Error!contract.Capabilities {
    _ = try self.rootPath(root);
    return .{};
}

pub fn sameRoot(self: *ShellProvider, left: contract.Root, right: contract.Root) contract.Error!bool {
    return std.mem.eql(u8, try self.rootPath(left), try self.rootPath(right));
}

pub fn deriveRoot(self: *ShellProvider, source: contract.EntrySource) contract.Error!contract.Root {
    const path = try self.nodePath(source.root, .{ .entry = source.ref });
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const now = try self.observePath(arena.allocator(), .{ .entry = source.ref }, path);
    if (now.kind != .directory) return error.NotDirectory;
    if (!std.mem.eql(u8, now.revision.token, source.revision.token)) return error.Stale;
    return self.acquireRoot(path);
}

/// Roots are path names, never reused; there is nothing on the far side
/// to let go of.
pub fn releaseRoot(_: *ShellProvider, _: contract.Root) void {}

pub fn observe(self: *ShellProvider, gpa: Allocator, root: contract.Root, node: contract.NodeRef) contract.Error!contract.OwnedObservation {
    const path = try self.nodePath(root, node);
    var owned = contract.OwnedObservation.init(gpa);
    errdefer owned.deinit();
    owned.value = try self.observePath(owned.allocator(), node, path);
    return owned;
}

pub fn list(self: *ShellProvider, gpa: Allocator, root: contract.Root, directory: contract.NodeRef) contract.Error!contract.OwnedListing {
    const path = try self.nodePath(root, directory);
    var listing = self.channel.list(self.gpa, path) catch |err| return mapError(err);
    defer listing.deinit(self.gpa);
    var owned = contract.OwnedListing.init(gpa);
    errdefer owned.deinit();
    const arena = owned.allocator();
    var entries: std.ArrayList(contract.DirEntry) = .empty;
    for (listing.entries) |e| {
        const name = contract.Name.init(try arena.dupe(u8, e.name)) catch continue;
        const ref = try self.intern(path, e.name);
        try entries.append(arena, .{ .name = name, .observation = try observation(arena, .{ .entry = ref }, e) });
    }
    const stamp = try normalize(arena, listing.stamp);
    owned.value = .{
        .directory = .{ .node = directory, .revision = .{ .token = stamp }, .kind = .directory },
        .revision = .{ .token = stamp },
        .entries = try entries.toOwnedSlice(arena),
    };
    return owned;
}

pub fn read(self: *ShellProvider, gpa: Allocator, request: contract.ReadRequest) contract.Error!contract.OwnedReadResult {
    const source = switch (request.source) {
        .entry => |entry| entry,
        .lease => return error.Unsupported,
    };
    const path = try self.nodePath(source.root, .{ .entry = source.ref });
    var owned = contract.OwnedReadResult.init(gpa);
    errdefer owned.deinit();
    const arena = owned.allocator();
    const now = try self.observePath(arena, .{ .entry = source.ref }, path);
    if (now.kind != .regular) return error.Unsupported;
    if (!std.mem.eql(u8, now.revision.token, source.revision.token)) return error.Stale;
    const bytes = if (request.limit) |limit|
        self.channel.readRange(arena, path, request.offset, limit) catch |err| return mapError(err)
    else blk: {
        const whole = self.channel.readAll(arena, path) catch |err| return mapError(err);
        break :blk whole[@min(whole.len, request.offset)..];
    };
    owned.value = .{
        .observation = now,
        .bytes = bytes,
        .eof = if (request.limit) |limit| bytes.len < limit else true,
    };
    return owned;
}

pub fn capture(_: *ShellProvider, _: contract.EntrySource) contract.Error!contract.LeaseRef {
    return error.Unsupported;
}

pub fn releaseLease(_: *ShellProvider, _: contract.LeaseSource) void {}

pub fn apply(_: *ShellProvider, _: Allocator, _: contract.Plan) contract.Error!contract.OwnedApplyReport {
    return error.Unsupported;
}

pub fn watch(_: *ShellProvider, _: contract.Root, _: contract.NodeRef, _: bool) contract.Error!contract.WatchRef {
    return error.Unsupported;
}

pub fn pollInvalidation(_: *ShellProvider, _: contract.WatchRef) contract.Error!?contract.Invalidation {
    return error.Unsupported;
}

pub fn closeWatch(_: *ShellProvider, _: contract.WatchRef) void {}

// ── Tests (a local /bin/sh — the same protocol ssh would carry) ─────

const t = std.testing;

test "shell provider: lists, observes, reads and derives children by path, and refuses what the tier cannot do" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "alpha\n" });
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/b.txt", .data = "bee\n" });
    var cwd_buf: [4096]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwd;
    const cwd = std.mem.sliceTo(cwd_ptr, 0);
    const root_path = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/tmp/{s}", .{ cwd, tmp.sub_path });
    defer gpa.free(root_path);

    var channel = try ShellFs.spawn(gpa, &.{"/bin/sh"}, .{ .block = .{ .slice = std.mem.span(std.c.environ) } });
    defer channel.deinit();
    var p = ShellProvider.init(gpa, &channel, @enumFromInt(5));
    defer p.deinit();

    const root = try p.acquireRoot(root_path);
    var listing = try p.list(gpa, root, .root);
    defer listing.deinit();
    var file: ?contract.DirEntry = null;
    var dir: ?contract.DirEntry = null;
    for (listing.value.entries) |e| {
        if (std.mem.eql(u8, e.name.bytes, "a.txt")) file = e;
        if (std.mem.eql(u8, e.name.bytes, "sub")) dir = e;
    }
    try t.expectEqual(contract.Kind.regular, file.?.observation.kind);
    try t.expectEqual(contract.Kind.directory, dir.?.observation.kind);

    // A listing's stamp and a lone observation of the same file agree.
    var seen = try p.observe(gpa, root, file.?.observation.node);
    defer seen.deinit();
    try t.expectEqualStrings(file.?.observation.revision.token, seen.value.revision.token);

    // Listing again names the same children with the same refs.
    var again = try p.list(gpa, root, .root);
    defer again.deinit();
    for (again.value.entries) |e| if (std.mem.eql(u8, e.name.bytes, "a.txt")) {
        try t.expect(std.meta.eql(e.observation.node, file.?.observation.node));
    };

    const file_ref = file.?.observation.node.entry;
    var bytes = try p.read(gpa, .{ .source = .{ .entry = .{ .root = root, .ref = file_ref, .revision = file.?.observation.revision } } });
    defer bytes.deinit();
    try t.expectEqualStrings("alpha\n", bytes.value.bytes);
    try t.expectError(error.Stale, p.read(gpa, .{ .source = .{ .entry = .{ .root = root, .ref = file_ref, .revision = .{ .token = "not it" } } } }));

    const child = try p.deriveRoot(.{ .root = root, .ref = dir.?.observation.node.entry, .revision = dir.?.observation.revision });
    var inner = try p.list(gpa, child, .root);
    defer inner.deinit();
    try t.expectEqual(@as(usize, 1), inner.value.entries.len);
    try t.expectEqualStrings("b.txt", inner.value.entries[0].name.bytes);
    // A child root is confined: an entry of its parent is not beneath it.
    try t.expectError(error.Confined, p.observe(gpa, child, .{ .entry = file_ref }));

    try t.expectError(error.Unsupported, p.capture(.{ .root = root, .ref = file_ref, .revision = file.?.observation.revision }));
    try t.expectEqual(contract.Capabilities{}, try p.capabilities(root));
}
