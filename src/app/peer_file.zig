//! A file in a peer's shared tree as an entry's backing (`core.backing.
//! Remote`): the peer tier of the one remote-file discipline the shell tier
//! also rides (substrate §2). The file is reached the way the shell's
//! directories are — from the tree the peer shares, name by name through the
//! provider's own listings (`directory`) — and its bytes cross through the
//! peer filesystem's export surfaces: `bytes` to read it, `mutate` to write
//! it, each granted or not by the peer (`--share-fs`, `share-fs`).
//!
//! A save is the guarded test-and-set, over the portable filesystem plan:
//! the new bytes land beside the file in a temp (`create_file`, exclusive),
//! then replace it by rename only while it is still the revision this side
//! last merged (`rename` with `expected = .entry`) — else STALE, and the
//! backing merges the peer's disk and retries. An external change is merged
//! as the backing peer's ops, like any other tier's. Tokens are the peer
//! provider's revision tokens: opaque, compared for equality only.
//!
//! Calls run on the thread that asked (`Affinity.caller`): the tree's
//! transport is the connection the frame thread ticks.

const std = @import("std");
const core = @import("weft_core");
const fs = @import("weft_fs");
const fs_runtime = @import("weft_fs_runtime");
const semantic = @import("weft_semantic");
const ShareCtx = @import("collab.zig").ShareCtx;

const contract = fs.contract;
const RemoteError = core.backing.RemoteError;

const PeerFile = @This();

sc: *ShareCtx,
services: *core.semantic.Services,
router: *fs_runtime.Router,
fingerprint: []u8,
/// The file's path in the peer's tree (`/src/main.zig`).
path: []u8,

/// Why a peer's file cannot be written — the reason its entry refuses edits.
pub const refuse_no_write = "read-only: the peer shares this tree without a write grant";

/// The directory `path` names in the tree peer `fingerprint` shares with
/// us, reached from the root by names in the provider's own listings — or
/// null, with the refusal in `why`, when that is not the peer we are
/// connected to or it has no such directory.
pub fn directory(sc: *ShareCtx, services: *core.semantic.Services, router: *fs_runtime.Router, fingerprint: []const u8, path: []const u8, why: *[]const u8) !?semantic.target.Located {
    const root = sc.remote_fs_target orelse {
        why.* = "open: that peer shares no filesystem with us";
        return null;
    };
    const s = sc.session.* orelse {
        why.* = core.designation.refuse_unreachable;
        return null;
    };
    const connected = s.peerFingerprint() orelse {
        why.* = core.designation.refuse_unreachable;
        return null;
    };
    if (!std.mem.eql(u8, &connected, fingerprint)) {
        why.* = "open: that peer is not the one we are connected to";
        return null;
    }
    var at = root;
    var names = std.mem.tokenizeScalar(u8, path, '/');
    while (names.next()) |name| {
        at = (try sc.remoteChild(services, router, at, name)) orelse {
            why.* = "open: the peer has no such directory";
            return null;
        };
    }
    return at;
}

/// A `Remote` for the file at `path` in peer `fingerprint`'s tree. Owned by
/// the backing it is handed to.
pub fn create(gpa: std.mem.Allocator, sc: *ShareCtx, services: *core.semantic.Services, router: *fs_runtime.Router, fingerprint: []const u8, path: []const u8) !core.backing.Remote {
    const self = try gpa.create(PeerFile);
    errdefer gpa.destroy(self);
    const fp = try gpa.dupe(u8, fingerprint);
    errdefer gpa.free(fp);
    self.* = .{ .sc = sc, .services = services, .router = router, .fingerprint = fp, .path = try gpa.dupe(u8, path) };
    return .{ .ctx = self, .vtable = &vtable };
}

/// Whether the peer lets this side write its tree: the `mutate` surface.
/// Read from the capabilities the peer's server answers, which it narrows
/// for a grantee without that surface — no exclusive create means no save,
/// because a save starts with one.
pub fn writable(self: *PeerFile) bool {
    var why: []const u8 = "";
    const parent = (directory(self.sc, self.services, self.router, self.fingerprint, self.dirPath(), &why) catch return false) orelse return false;
    const dir = self.router.authorizedDirectory(parent.target, parent.revision) catch return false;
    const caps = self.router.capabilities(dir.root) catch return false;
    return caps.exclusive_create;
}

pub fn of(remote: core.backing.Remote) ?*PeerFile {
    return if (remote.vtable == &vtable) cast(remote.ctx) else null;
}

const vtable: core.backing.Remote.VTable = .{
    .label = "peer",
    .affinity = .caller,
    .path = pathOf,
    .fetch = fetch,
    .write = write,
    .deinit = deinit,
};

fn cast(ctx: *anyopaque) *PeerFile {
    return @ptrCast(@alignCast(ctx));
}

fn pathOf(ctx: *anyopaque) []const u8 {
    return cast(ctx).path;
}

fn dirPath(self: *const PeerFile) []const u8 {
    return std.fs.path.dirnamePosix(self.path) orelse "/";
}

fn leaf(self: *const PeerFile) []const u8 {
    return std.fs.path.basenamePosix(self.path);
}

fn mapError(err: anyerror) RemoteError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Stale => error.Stale,
        error.PermissionDenied => error.NotPermitted,
        error.NotFound => error.Failed,
        else => error.Unreachable,
    };
}

/// The directory the file is in, as the router authorizes it.
fn parentDirectory(self: *PeerFile) RemoteError!fs.target.Directory {
    var why: []const u8 = "";
    const parent = (directory(self.sc, self.services, self.router, self.fingerprint, self.dirPath(), &why) catch |err| return mapError(err)) orelse return error.Unreachable;
    return self.router.authorizedDirectory(parent.target, parent.revision) catch |err| mapError(err);
}

/// `name` in `dir` as the provider lists it now: its ref and revision
/// (the token, owned by `gpa`), or null when there is no regular file.
const Found = struct { ref: contract.EntryRef, token: []u8 };

fn find(self: *PeerFile, gpa: std.mem.Allocator, dir: fs.target.Directory, name: []const u8) RemoteError!?Found {
    var listing = self.router.list(gpa, dir.root, dir.node) catch |err| return mapError(err);
    defer listing.deinit();
    for (listing.value.entries) |e| {
        if (!std.mem.eql(u8, e.name.bytes, name)) continue;
        if (e.observation.kind != .regular) return error.Failed;
        const ref = switch (e.observation.node) {
            .entry => |r| r,
            .root => return error.Failed,
        };
        return .{ .ref = ref, .token = try gpa.dupe(u8, e.observation.revision.token) };
    }
    return null;
}

fn fetch(ctx: *anyopaque, gpa: std.mem.Allocator, expected: ?[]const u8) RemoteError!?core.backing.Fetched {
    const self = cast(ctx);
    const dir = try self.parentDirectory();
    const found = (try self.find(gpa, dir, self.leaf())) orelse return error.Failed;
    errdefer gpa.free(found.token);
    if (expected) |e| if (std.mem.eql(u8, e, found.token)) {
        gpa.free(found.token);
        return null;
    };
    var read = self.router.read(gpa, .{ .source = .{ .entry = .{ .root = dir.root, .ref = found.ref, .revision = .{ .token = found.token } } } }) catch |err| return mapError(err);
    defer read.deinit();
    return .{ .bytes = try gpa.dupe(u8, read.value.bytes), .token = found.token };
}

fn parentRef(dir: fs.target.Directory) contract.ParentRef {
    return switch (dir.node) {
        .root => .root,
        .entry => |e| .{ .entry = e },
    };
}

/// Apply a one-operation plan; its outcome.
fn applyOne(self: *PeerFile, gpa: std.mem.Allocator, dir: fs.target.Directory, operation: contract.Operation, id: u8) RemoteError!std.meta.Tag(contract.Outcome) {
    var op_id: contract.OperationId = @splat(0);
    op_id[0] = id;
    const plan = [_]contract.Planned{.{ .id = op_id, .operation = operation }};
    var report = self.router.apply(gpa, .{ .root = dir.root, .base_revision = &.{}, .operations = &plan }) catch |err| return mapError(err);
    defer report.deinit();
    return std.meta.activeTag(report.value.entries[0].outcome);
}

fn write(ctx: *anyopaque, gpa: std.mem.Allocator, bytes: []const u8, expected: ?[]const u8) RemoteError![]u8 {
    const self = cast(ctx);
    const dir = try self.parentDirectory();
    const name = self.leaf();
    // Test: the file is still what this side last merged (or still absent).
    const current = try self.find(gpa, dir, name);
    defer if (current) |c| gpa.free(c.token);
    if (expected) |e| {
        const c = current orelse return error.Stale;
        if (!std.mem.eql(u8, c.token, e)) return error.Stale;
    } else if (current != null) return error.Stale;

    // Upload beside it.
    const tmp_name = try std.fmt.allocPrint(gpa, ".{s}.weft-tmp", .{name});
    defer gpa.free(tmp_name);
    const tmp_slot: contract.Slot = .{ .parent = parentRef(dir), .name = contract.Name.init(tmp_name) catch return error.Failed };
    switch (try self.applyOne(gpa, dir, .{ .create_file = .{ .destination = tmp_slot, .contents = bytes } }, 1)) {
        .applied => {},
        .stale => return error.Stale,
        else => return error.Failed,
    }
    const tmp = (try self.find(gpa, dir, tmp_name)) orelse return error.Failed;
    defer gpa.free(tmp.token);

    // Set: move it over the file iff the file is still the one tested.
    const destination: contract.Slot = .{ .parent = parentRef(dir), .name = contract.Name.init(name) catch return error.Failed };
    const guard: contract.Expected = if (current) |c| .{ .entry = .{ .ref = c.ref, .revision = .{ .token = c.token } } } else .absent;
    const moved = self.applyOne(gpa, dir, .{ .rename = .{
        .source = .{ .root = dir.root, .ref = tmp.ref, .revision = .{ .token = tmp.token } },
        .destination = destination,
        .expected = guard,
    } }, 2) catch |err| {
        self.discard(gpa, dir, tmp);
        return err;
    };
    switch (moved) {
        .applied => {},
        .stale, .conflict => {
            self.discard(gpa, dir, tmp);
            return error.Stale;
        },
        else => {
            self.discard(gpa, dir, tmp);
            return error.Failed;
        },
    }
    // The written content's token: the file as the provider lists it now.
    const landed = (try self.find(gpa, dir, name)) orelse return error.Failed;
    return landed.token;
}

/// Take the temp back after a failed move. Best effort: a temp left behind
/// is litter, never a lost update.
fn discard(self: *PeerFile, gpa: std.mem.Allocator, dir: fs.target.Directory, tmp: Found) void {
    _ = self.applyOne(gpa, dir, .{ .remove = .{
        .source = .{ .root = dir.root, .ref = tmp.ref, .revision = .{ .token = tmp.token } },
        .policy = .permanent,
    } }, 3) catch {};
}

fn deinit(ctx: *anyopaque, gpa: std.mem.Allocator) void {
    const self = cast(ctx);
    gpa.free(self.fingerprint);
    gpa.free(self.path);
    gpa.destroy(self);
}
