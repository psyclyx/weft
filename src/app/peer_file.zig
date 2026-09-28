//! A file in a peer's shared tree as an entry's backing (`core.backing.
//! Remote`): the peer tier of the one remote-file discipline the shell tier
//! also rides (substrate §2). The file is reached the way the shell's
//! directories are — from the tree the peer shares, name by name through the
//! provider's own listings (`directory`) — and its bytes cross through the
//! peer filesystem's export surfaces: `bytes` to read it, `mutate` to write
//! it, each granted or not by the peer (`--share-fs`, `collab.share-fs`).
//!
//! A save is the guarded test-and-set, over the portable filesystem plan:
//! the new bytes land beside the file in a temp (`create_file`, exclusive,
//! with the file's observed mode, under a random name — a temp a lost save
//! left is taken back by the next save's listing, never collided with),
//! then replace it by rename only while it is still the revision this side
//! last merged (`rename` with `expected = .entry`) — else STALE, and the
//! backing merges the peer's disk and retries. An external change is merged
//! as the backing peer's ops, like any other tier's. Tokens are the peer
//! provider's revision tokens: opaque, compared for equality only.
//!
//! Calls run on a pool worker (`Affinity.worker`), never the frame: the
//! frame resolves the file's directory and provider (`prepare`), the worker
//! drives the provider, and the tree's transport — the connection the frame
//! thread ticks — carries the worker's requests through that tick
//! (`collab.RemoteExchange`).

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
/// Its directory and the provider serving it, resolved on the frame thread
/// (`prepare`) — the semantic targets and the router are the frame's — and
/// read by the worker the call runs on. Under `mutex`: a poll's worker may
/// still be reading while the frame prepares a save.
at: ?Resolved = null,
mutex: core.task.Mutex = .{},

const Resolved = struct { dir: fs.target.Directory, provider: fs.service.Provider };

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

/// A peer's tree rides the connection the frame thread ticks — and a slow
/// peer must not stall a frame — so the calls run on a pool worker: the
/// frame resolves where the file is (`prepare`), the worker drives the
/// provider, and the provider's round trips go through the connection's
/// tick (`collab.RemoteExchange`), never touching the connection itself.
const vtable: core.backing.Remote.VTable = .{
    .label = "peer",
    .affinity = .worker,
    .prepare = prepare,
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

/// The directory the file is in, as the router authorizes it. The frame's.
fn parentDirectory(self: *PeerFile) RemoteError!fs.target.Directory {
    var why: []const u8 = "";
    const parent = (directory(self.sc, self.services, self.router, self.fingerprint, self.dirPath(), &why) catch |err| return mapError(err)) orelse return error.Unreachable;
    return self.router.authorizedDirectory(parent.target, parent.revision) catch |err| mapError(err);
}

/// On the frame thread, before a call leaves it: where the file is now, and
/// who serves it. Cheap once the directory has been reached (the children
/// along the way are kept), so every save and poll re-resolves — a peer that
/// reconnected is found again.
fn prepare(ctx: *anyopaque) RemoteError!void {
    const self = cast(ctx);
    const dir = try self.parentDirectory();
    const provider = self.router.providerOf(dir.root) catch |err| return mapError(err);
    self.mutex.lock();
    defer self.mutex.unlock();
    self.at = .{ .dir = dir, .provider = provider };
}

/// What `prepare` resolved, for the worker.
fn resolved(self: *PeerFile) RemoteError!Resolved {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.at orelse error.Unreachable;
}

/// `name` in `dir` as the provider lists it now: its ref and revision
/// (the token, owned by `gpa`), or null when there is no regular file.
/// Its permission bits too, when the provider says them — what a save's temp
/// is created with, so the move keeps them.
const Found = struct { ref: contract.EntryRef, token: []u8, mode: ?u32 = null };

fn find(self: *PeerFile, gpa: std.mem.Allocator, at: Resolved, name: []const u8) RemoteError!?Found {
    return self.scan(gpa, at, name, null);
}

/// `find`, and — when `litter` is given — every temp an earlier save of
/// `name` left behind (its connection lost between upload and move), taken
/// back as it is seen: one listing either way.
fn scan(self: *PeerFile, gpa: std.mem.Allocator, at: Resolved, name: []const u8, litter: ?[]const u8) RemoteError!?Found {
    var listing = at.provider.list(gpa, at.dir.root, at.dir.node) catch |err| return mapError(err);
    defer listing.deinit();
    var found: ?Found = null;
    errdefer if (found) |f| gpa.free(f.token);
    for (listing.value.entries) |e| {
        const ref = switch (e.observation.node) {
            .entry => |r| r,
            .root => continue,
        };
        if (litter) |prefix| if (e.observation.kind == .regular and isTemp(e.name.bytes, prefix)) {
            self.discard(gpa, at, ref, e.observation.revision.token);
            continue;
        };
        if (!std.mem.eql(u8, e.name.bytes, name)) continue;
        if (e.observation.kind != .regular) return error.Failed;
        found = .{
            .ref = ref,
            .token = try gpa.dupe(u8, e.observation.revision.token),
            .mode = if (e.observation.metadata.mode) |m| m & 0o777 else null,
        };
    }
    return found;
}

/// A save's temp for the file `prefix` names: `prefix` then the random
/// suffix, or the fixed name saves used before temps had one.
fn isTemp(name: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, name, prefix) or std.mem.eql(u8, name, prefix[0 .. prefix.len - 1]);
}

fn fetch(ctx: *anyopaque, gpa: std.mem.Allocator, expected: ?[]const u8) RemoteError!?core.backing.Fetched {
    const self = cast(ctx);
    const at = try self.resolved();
    const found = (try self.find(gpa, at, self.leaf())) orelse return error.Failed;
    errdefer gpa.free(found.token);
    if (expected) |e| if (std.mem.eql(u8, e, found.token)) {
        gpa.free(found.token);
        return null;
    };
    var read = at.provider.read(gpa, .{ .source = .{ .entry = .{ .root = at.dir.root, .ref = found.ref, .revision = .{ .token = found.token } } } }) catch |err| return mapError(err);
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
fn applyOne(_: *PeerFile, gpa: std.mem.Allocator, at: Resolved, operation: contract.Operation, id: u8) RemoteError!std.meta.Tag(contract.Outcome) {
    var op_id: contract.OperationId = @splat(0);
    op_id[0] = id;
    const plan = [_]contract.Planned{.{ .id = op_id, .operation = operation }};
    const effect_plan: contract.Plan = .{ .root = at.dir.root, .base_revision = &.{}, .operations = &plan };
    // What the router checks before it hands a plan on (`Router.apply`).
    fs.plan.validate(gpa, effect_plan) catch |err| return mapError(err);
    var report = at.provider.apply(gpa, effect_plan) catch |err| return mapError(err);
    defer report.deinit();
    return std.meta.activeTag(report.value.entries[0].outcome);
}

fn write(ctx: *anyopaque, gpa: std.mem.Allocator, bytes: []const u8, expected: ?[]const u8) RemoteError![]u8 {
    const self = cast(ctx);
    const at = try self.resolved();
    const name = self.leaf();
    // A fresh temp name, and the prefix every save of this file's temp has.
    const temp = try core.ShellFs.tempName(gpa, std.Io.Threaded.global_single_threaded.io(), name);
    defer gpa.free(temp.prefix);
    defer gpa.free(temp.name);
    // Test: the file is still what this side last merged (or still absent),
    // taking back what a lost save left beside it on the way.
    const current = try self.scan(gpa, at, name, temp.prefix);
    defer if (current) |c| gpa.free(c.token);
    if (expected) |e| {
        const c = current orelse return error.Stale;
        if (!std.mem.eql(u8, c.token, e)) return error.Stale;
    } else if (current != null) return error.Stale;

    // Upload beside it, with the file's own mode (an executable stays one).
    const tmp_name = temp.name;
    const tmp_slot: contract.Slot = .{ .parent = parentRef(at.dir), .name = contract.Name.init(tmp_name) catch return error.Failed };
    const mode = if (current) |c| c.mode else null;
    switch (try self.applyOne(gpa, at, .{ .create_file = .{ .destination = tmp_slot, .contents = bytes, .mode = mode } }, 1)) {
        .applied => {},
        .stale => return error.Stale,
        else => return error.Failed,
    }
    const tmp = (try self.find(gpa, at, tmp_name)) orelse return error.Failed;
    defer gpa.free(tmp.token);

    // Set: move it over the file iff the file is still the one tested.
    const destination: contract.Slot = .{ .parent = parentRef(at.dir), .name = contract.Name.init(name) catch return error.Failed };
    const guard: contract.Expected = if (current) |c| .{ .entry = .{ .ref = c.ref, .revision = .{ .token = c.token } } } else .absent;
    const moved = self.applyOne(gpa, at, .{ .rename = .{
        .source = .{ .root = at.dir.root, .ref = tmp.ref, .revision = .{ .token = tmp.token } },
        .destination = destination,
        .expected = guard,
    } }, 2) catch |err| {
        self.discard(gpa, at, tmp.ref, tmp.token);
        return err;
    };
    switch (moved) {
        .applied => {},
        .stale, .conflict => {
            self.discard(gpa, at, tmp.ref, tmp.token);
            return error.Stale;
        },
        else => {
            self.discard(gpa, at, tmp.ref, tmp.token);
            return error.Failed;
        },
    }
    // The written content's token: the file as the provider lists it now.
    const landed = (try self.find(gpa, at, name)) orelse return error.Failed;
    return landed.token;
}

/// Take a temp back — after a failed move, or one a lost save left. Best
/// effort: a temp left behind is litter (the next save takes it), never a
/// lost update.
fn discard(self: *PeerFile, gpa: std.mem.Allocator, at: Resolved, ref: contract.EntryRef, token: []const u8) void {
    _ = self.applyOne(gpa, at, .{ .remove = .{
        .source = .{ .root = at.dir.root, .ref = ref, .revision = .{ .token = token } },
        .policy = .permanent,
    } }, 3) catch {};
}

fn deinit(ctx: *anyopaque, gpa: std.mem.Allocator) void {
    const self = cast(ctx);
    gpa.free(self.fingerprint);
    gpa.free(self.path);
    gpa.destroy(self);
}
