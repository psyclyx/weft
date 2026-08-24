//! Linux implementation of the portable `weft_fs` provider contract.
//!
//! Root acquisition is the only path-shaped API. It pins a directory fd;
//! every later operation walks provider-minted parent handles one raw leaf at
//! a time with `*at` syscalls. Entry handles therefore carry identity without
//! granting string-path authority, and symlinks are never followed implicitly.

const std = @import("std");
const fs = @import("weft_fs");

const contract = fs.contract;
const linux = std.os.linux;

const revision_len = 88;
const revision_magic: u32 = 0x31584657; // "WFX1", little endian.

var generation_nonce: std.atomic.Value(u32) = .init(1);

pub const LinuxFs = struct {
    pub const lease_capability: contract.LeaseCapability = .{
        .regular_file_max_bytes = 64 * 1024 * 1024,
        .symlink_target_max_bytes = 64 * 1024,
    };
    gpa: std.mem.Allocator,
    generation_seed: u32,
    roots: std.ArrayList(RootSlot) = .empty,
    entries: std.ArrayList(EntrySlot) = .empty,
    leases: std.ArrayList(LeaseSlot) = .empty,

    const RootSlot = struct {
        generation: u32,
        value: ?RootState = null,
    };

    const RootState = struct {
        fd: i32,
        identity: Identity,
    };

    const EntrySlot = struct {
        generation: u32,
        value: ?EntryState = null,
    };

    /// A lease is a provider-owned materialized file value. Directory trees
    /// deliberately remain unsupported until their snapshot/space bounds are
    /// specified; retaining an open fd would not be portable or durable.
    const LeaseSlot = struct {
        generation: u32,
        value: ?LeaseState = null,
    };

    const LeaseState = struct {
        root: contract.Root,
        kind: contract.Kind,
        contents: []u8 = &.{},
        link_target: []u8 = &.{},
        mode: u32,
    };

    const EntryState = struct {
        root: contract.Root,
        parent: contract.NodeRef,
        name: []u8,
        identity: Identity,
        /// Last revision observed by a successful list or provider mutation.
        /// Guards still compare the caller's revision to fresh `statx` data.
        revision: [revision_len]u8,
    };

    const Identity = struct {
        dev_major: u32,
        dev_minor: u32,
        mount_id: u64,
        inode: u64,
        has_birth_time: bool,
        birth_sec: i64,
        birth_nsec: u32,

        /// A `(device, mount, inode)` tuple is useful for reasoning about
        /// already-open descriptors, but it is not proof that two path
        /// lookups named the same object: inode reuse can make a replacement
        /// look identical when the filesystem does not provide birth time.
        fn locationEql(a: Identity, b: Identity) bool {
            return a.dev_major == b.dev_major and
                a.dev_minor == b.dev_minor and
                a.mount_id == b.mount_id and
                a.inode == b.inode;
        }

        /// Exact object identity is intentionally unavailable when either
        /// statx result lacks BTIME. We do not retain one fd per entry just to
        /// manufacture that guarantee; callers must report stale/ambiguous
        /// instead of accepting an unprovable replacement.
        fn eql(a: Identity, b: Identity) bool {
            return a.has_birth_time and b.has_birth_time and
                a.locationEql(b) and
                a.birth_sec == b.birth_sec and
                a.birth_nsec == b.birth_nsec;
        }
    };

    const Snapshot = struct {
        identity: Identity,
        kind: contract.Kind,
        mode: u32,
        size: u64,
        nlink: u32,
        modified_sec: i64,
        modified_nsec: u32,
        changed_sec: i64,
        changed_nsec: u32,
    };

    const ResolvedEntry = struct {
        parent_fd: i32,
        state: *const EntryState,
        snapshot: Snapshot,

        fn close(self: ResolvedEntry) void {
            closeFd(self.parent_fd);
        }
    };

    const ResolvedDirectory = struct {
        fd: i32,
        node: contract.NodeRef,
        snapshot: Snapshot,

        fn close(self: ResolvedDirectory) void {
            closeFd(self.fd);
        }
    };

    const Execution = struct {
        outcome: contract.Outcome,
        output: ?contract.EntryRef = null,
    };

    const PendingEntry = struct {
        name: []const u8,
        snapshot: Snapshot,
        link_target: ?[]const u8,
    };

    const CopyError = contract.Error || error{Partial};
    const RemoveError = contract.Error || error{Partial};

    pub fn init(gpa: std.mem.Allocator) LinuxFs {
        var seed = generation_nonce.fetchAdd(1, .monotonic) +% 1;
        if (seed == 0) seed = 1;
        return .{ .gpa = gpa, .generation_seed = seed };
    }

    pub fn deinit(self: *LinuxFs) void {
        for (self.entries.items) |*slot| self.clearEntrySlot(slot);
        self.entries.deinit(self.gpa);
        for (self.roots.items) |*slot| {
            if (slot.value) |root| closeFd(root.fd);
            slot.value = null;
        }
        self.roots.deinit(self.gpa);
        for (self.leases.items) |*slot| self.clearLeaseSlot(slot);
        self.leases.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn provider(self: *LinuxFs) fs.service.Provider {
        return .init(self);
    }

    /// Acquire and pin a directory. The supplied path is interpreted only at
    /// this authority boundary and is never retained or re-resolved.
    pub fn acquireRoot(self: *LinuxFs, path: []const u8) contract.Error!contract.Root {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidName;
        const path_z = try self.gpa.dupeZ(u8, path);
        defer self.gpa.free(path_z);
        const rc = linux.openat(linux.AT.FDCWD, path_z.ptr, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0);
        const fd = try fdResult(rc);
        errdefer closeFd(fd);
        const snapshot = try statFd(fd);
        if (snapshot.kind != .directory) return error.NotDirectory;

        for (self.roots.items, 0..) |*slot, index| {
            if (slot.value != null) continue;
            slot.value = .{ .fd = fd, .identity = snapshot.identity };
            return .{ .authority = .here, .slot = @intCast(index), .generation = slot.generation };
        }
        try self.roots.append(self.gpa, .{
            .generation = self.generation_seed,
            .value = .{ .fd = fd, .identity = snapshot.identity },
        });
        return .{
            .authority = .here,
            .slot = @intCast(self.roots.items.len - 1),
            .generation = self.roots.items[self.roots.items.len - 1].generation,
        };
    }

    pub fn releaseRoot(self: *LinuxFs, root: contract.Root) void {
        const slot = self.rootSlot(root) orelse return;
        const state = slot.value orelse return;
        for (self.entries.items) |*entry_slot| {
            if (entry_slot.value) |entry|
                if (entry.root.eql(root)) self.clearEntrySlot(entry_slot);
        }
        closeFd(state.fd);
        slot.value = null;
        bumpGeneration(&slot.generation);
    }

    pub fn capabilities(self: *LinuxFs, root: contract.Root) contract.Error!contract.Capabilities {
        _ = try self.rootState(root);
        return .{
            .exclusive_create = true,
            .durable_lease = lease_capability,
            .symlink = true,
            .posix_mode = true,
            .guard_strength = .preflight,
            .watch = .none,
            .quarantine = false,
        };
    }

    pub fn observe(
        self: *LinuxFs,
        gpa: std.mem.Allocator,
        root: contract.Root,
        node: contract.NodeRef,
    ) contract.Error!contract.OwnedObservation {
        var owned = contract.OwnedObservation.init(gpa);
        errdefer owned.deinit();
        const arena = owned.allocator();
        owned.value = switch (node) {
            .root => blk: {
                const root_state = try self.rootState(root);
                break :blk try self.observation(arena, .root, try statFd(root_state.fd), null, null);
            },
            .entry => |entry| blk: {
                const resolved = try self.resolveEntry(root, entry);
                defer resolved.close();
                break :blk try self.observation(
                    arena,
                    .{ .entry = entry },
                    resolved.snapshot,
                    resolved.parent_fd,
                    resolved.state.name,
                );
            },
        };
        return owned;
    }

    pub fn list(
        self: *LinuxFs,
        gpa: std.mem.Allocator,
        root: contract.Root,
        directory: contract.NodeRef,
    ) contract.Error!contract.OwnedListing {
        var resolved = try self.resolveDirectory(root, directory);
        defer resolved.close();
        const start = resolved.snapshot;

        var owned = contract.OwnedListing.init(gpa);
        errdefer owned.deinit();
        const arena = owned.allocator();
        var pending: std.ArrayList(PendingEntry) = .empty;

        var buffer: [16 * 1024]u8 align(@alignOf(linux.dirent64)) = undefined;
        while (true) {
            const rc = linux.getdents64(resolved.fd, &buffer, buffer.len);
            const bytes_read = switch (linux.errno(rc)) {
                .SUCCESS => rc,
                .INTR => continue,
                .ACCES, .PERM => return error.PermissionDenied,
                else => return error.Io,
            };
            if (bytes_read == 0) break;
            var offset: usize = 0;
            while (offset < bytes_read) {
                const dirent: *align(1) const linux.dirent64 = @ptrCast(&buffer[offset]);
                if (dirent.reclen == 0 or offset + dirent.reclen > bytes_read) return error.Io;
                const name_z: [*:0]const u8 = @ptrCast(&buffer[offset + @offsetOf(linux.dirent64, "name")]);
                const raw_name = std.mem.span(name_z);
                offset += dirent.reclen;
                if (std.mem.eql(u8, raw_name, ".") or std.mem.eql(u8, raw_name, "..")) continue;
                const name = contract.Name.init(raw_name) catch return error.InvalidName;
                // Always stat: d_type is only a hint and DT_UNKNOWN is valid.
                const snapshot = statAt(self.gpa, resolved.fd, name.bytes) catch |err| switch (err) {
                    error.NotFound => continue,
                    else => return err,
                };
                const owned_name = try arena.dupe(u8, name.bytes);
                try pending.append(arena, .{
                    .name = owned_name,
                    .snapshot = snapshot,
                    .link_target = try self.captureLinkTarget(arena, resolved.fd, name.bytes, snapshot),
                });
            }
        }

        const finish = try statFd(resolved.fd);
        if (!sameRevision(finish, start)) return error.Stale;
        const entries = try arena.alloc(contract.DirEntry, pending.items.len);
        const entry_revisions = try arena.alloc([revision_len]u8, pending.items.len);
        for (pending.items, entry_revisions) |candidate, *revision| revision.* = revisionBytes(&candidate.snapshot);
        const directory_revision = try arena.create([revision_len]u8);
        directory_revision.* = revisionBytes(&finish);

        // Every allocation needed to publish the listing is complete before
        // reconciliation can invalidate or reuse an entry slot. The commit
        // loop below only assigns preallocated values and cannot fail.
        const refs = try self.reconcileDirectory(arena, root, directory, pending.items);
        for (pending.items, refs, entry_revisions, entries) |candidate, entry_ref, *revision, *entry| {
            entry.* = .{
                .name = contract.Name.init(candidate.name) catch unreachable,
                .observation = self.observationWithRevision(
                    .{ .entry = entry_ref },
                    candidate.snapshot,
                    candidate.link_target,
                    revision[0..],
                ),
            };
        }
        const directory_observation = self.observationWithRevision(
            directory,
            finish,
            null,
            directory_revision[0..],
        );
        owned.value = .{
            .directory = directory_observation,
            .revision = directory_observation.revision,
            .entries = entries,
        };
        return owned;
    }

    pub fn read(
        self: *LinuxFs,
        gpa: std.mem.Allocator,
        request: contract.ReadRequest,
    ) contract.Error!contract.OwnedReadResult {
        const source = switch (request.source) {
            .entry => |entry| entry,
            .lease => return error.Unsupported,
        };
        const resolved = try self.resolveEntry(source.root, source.ref);
        defer resolved.close();
        if (!revisionMatches(resolved.snapshot, source.revision)) return error.Stale;
        if (resolved.snapshot.kind != .regular) return error.Unsupported;
        const name_z = try checkedNameZ(self.gpa, resolved.state.name);
        defer self.gpa.free(name_z);
        const rc = linux.openat(resolved.parent_fd, name_z.ptr, .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, 0);
        const fd = try fdResult(rc);
        defer closeFd(fd);
        const opened = try statFd(fd);
        if (!opened.identity.eql(resolved.snapshot.identity) or !revisionMatches(opened, source.revision))
            return error.Stale;
        if (request.offset > opened.size) return error.Stale;

        var owned = contract.OwnedReadResult.init(gpa);
        errdefer owned.deinit();
        const arena = owned.allocator();
        var bytes: std.ArrayList(u8) = .empty;
        var offset = request.offset;
        var remaining = request.limit orelse std.math.maxInt(u64);
        var buffer: [64 * 1024]u8 = undefined;
        while (remaining != 0) {
            const wanted: usize = @intCast(@min(remaining, buffer.len));
            const read_rc = linux.pread(fd, &buffer, wanted, @bitCast(offset));
            const count = switch (linux.errno(read_rc)) {
                .SUCCESS => read_rc,
                .INTR => continue,
                .ACCES, .PERM => return error.PermissionDenied,
                else => return error.Io,
            };
            if (count == 0) break;
            try bytes.appendSlice(arena, buffer[0..count]);
            offset += count;
            remaining -= count;
        }
        const finish = try statFd(fd);
        if (!finish.identity.eql(opened.identity) or !revisionMatches(finish, source.revision)) return error.Stale;
        owned.value = .{
            .observation = try self.observation(arena, .{ .entry = source.ref }, finish, null, null),
            .bytes = bytes.items,
            .eof = offset >= finish.size,
        };
        return owned;
    }

    /// Materialize one regular file or symlink into provider-owned storage.
    /// The source is opened/read through the already pinned parent fd and
    /// checked again before publication, so deletion or replacement after
    /// capture cannot change what a later paste observes. Directory leasing
    /// is intentionally unsupported in this slice.
    pub fn capture(self: *LinuxFs, source: contract.EntrySource) contract.Error!contract.LeaseRef {
        const resolved = try self.resolveEntry(source.root, source.ref);
        defer resolved.close();
        if (!revisionMatches(resolved.snapshot, source.revision)) return error.Stale;
        if (resolved.snapshot.kind != .regular and resolved.snapshot.kind != .symlink) return error.Unsupported;

        var contents: []u8 = &.{};
        var link_target: []u8 = &.{};
        errdefer {
            self.gpa.free(contents);
            self.gpa.free(link_target);
        }
        if (resolved.snapshot.kind == .regular) {
            contents = try readWholeFile(
                self.gpa,
                resolved.parent_fd,
                resolved.state.name,
                resolved.snapshot,
                lease_capability.regular_file_max_bytes,
            );
        } else {
            link_target = try readlinkAtBounded(
                self.gpa,
                resolved.parent_fd,
                resolved.state.name,
                lease_capability.symlink_target_max_bytes,
            );
            const finish = try statAt(self.gpa, resolved.parent_fd, resolved.state.name);
            if (!finish.identity.eql(resolved.snapshot.identity) or !sameRevision(finish, resolved.snapshot)) return error.Stale;
        }
        const finish = try statAt(self.gpa, resolved.parent_fd, resolved.state.name);
        if (!finish.identity.eql(resolved.snapshot.identity) or !sameRevision(finish, resolved.snapshot)) return error.Stale;

        for (self.leases.items, 0..) |*slot, index| {
            if (slot.value != null) continue;
            slot.value = .{ .root = source.root, .kind = resolved.snapshot.kind, .contents = contents, .link_target = link_target, .mode = resolved.snapshot.mode };
            contents = &.{};
            link_target = &.{};
            return .{ .authority = source.root.authority, .slot = @intCast(index), .generation = slot.generation };
        }
        try self.leases.append(self.gpa, .{
            .generation = self.generation_seed,
            .value = .{ .root = source.root, .kind = resolved.snapshot.kind, .contents = contents, .link_target = link_target, .mode = resolved.snapshot.mode },
        });
        contents = &.{};
        link_target = &.{};
        return .{ .authority = source.root.authority, .slot = @intCast(self.leases.items.len - 1), .generation = self.leases.items[self.leases.items.len - 1].generation };
    }

    pub fn releaseLease(self: *LinuxFs, source: contract.LeaseSource) void {
        if (source.ref.authority != .here or source.ref.slot >= self.leases.items.len) return;
        const slot = &self.leases.items[source.ref.slot];
        if (slot.generation != source.ref.generation) return;
        if (slot.value) |lease| if (!lease.root.eql(source.root)) return;
        self.clearLeaseSlot(slot);
    }

    pub fn apply(
        self: *LinuxFs,
        gpa: std.mem.Allocator,
        effect_plan: contract.Plan,
    ) contract.Error!contract.OwnedApplyReport {
        const root_state = try self.rootState(effect_plan.root);
        const base_snapshot = try statFd(root_state.fd);
        const base_matches = effect_plan.base_revision.len == 0 or
            revisionMatches(base_snapshot, .{ .token = effect_plan.base_revision });

        var owned = contract.OwnedApplyReport.init(gpa);
        errdefer owned.deinit();
        const arena = owned.allocator();
        const reports = try arena.alloc(contract.ReportEntry, effect_plan.operations.len);
        const outputs = try arena.alloc(?contract.EntryRef, effect_plan.operations.len);
        @memset(outputs, null);

        for (effect_plan.operations, 0..) |planned, index| {
            reports[index].id = planned.id;
            if (!base_matches) {
                reports[index].outcome = .stale;
                continue;
            }
            var dependency_failed = false;
            for (planned.depends_on) |dependency| {
                if (dependency >= index) {
                    dependency_failed = true;
                    break;
                }
                const tag = std.meta.activeTag(reports[dependency].outcome);
                if (tag != .applied and tag != .already_satisfied) dependency_failed = true;
            }
            if (dependency_failed) {
                reports[index].outcome = .{ .conflict = "dependency did not apply" };
                continue;
            }

            const execution = self.execute(effect_plan.root, planned.operation, outputs) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => Execution{ .outcome = outcomeForError(err) },
            };
            reports[index].outcome = execution.outcome;
            outputs[index] = execution.output;
        }
        owned.value = .{ .entries = reports };
        return owned;
    }

    pub fn watch(
        self: *LinuxFs,
        root: contract.Root,
        directory: contract.NodeRef,
        recursive: bool,
    ) contract.Error!contract.WatchRef {
        _ = self;
        _ = root;
        _ = directory;
        _ = recursive;
        return error.Unsupported;
    }

    pub fn pollInvalidation(self: *LinuxFs, watch_ref: contract.WatchRef) contract.Error!?contract.Invalidation {
        _ = self;
        _ = watch_ref;
        return error.Unsupported;
    }

    pub fn closeWatch(self: *LinuxFs, watch_ref: contract.WatchRef) void {
        _ = self;
        _ = watch_ref;
    }

    fn execute(
        self: *LinuxFs,
        destination_root: contract.Root,
        operation: contract.Operation,
        outputs: []?contract.EntryRef,
    ) contract.Error!Execution {
        return switch (operation) {
            .create_file => |create| try self.createFile(destination_root, create, outputs),
            .create_directory => |create| try self.createDirectory(destination_root, create, outputs),
            .create_symlink => |create| try self.createSymlink(destination_root, create, outputs),
            .copy => |copy_op| try self.copy(destination_root, copy_op, outputs),
            .rename => |rename_op| try self.rename(destination_root, rename_op, outputs),
            .remove => |remove_op| try self.remove(remove_op),
            .set_permissions => |set| try self.setPermissions(set),
        };
    }

    fn createFile(self: *LinuxFs, root: contract.Root, create: anytype, outputs: []?contract.EntryRef) contract.Error!Execution {
        try requireExclusive(create.expected);
        if (create.mode) |mode| try validateMode(mode);
        const name_z = try checkedNameZ(self.gpa, create.destination.name.bytes);
        defer self.gpa.free(name_z);
        var parent = try self.resolveParent(root, create.destination.parent, outputs);
        defer parent.close();
        const rc = linux.openat(parent.fd, name_z.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, @intCast(create.mode orelse 0o644));
        const fd = try fdResult(rc);
        defer closeFd(fd);
        writeAll(fd, create.contents) catch return .{ .outcome = .{ .ambiguous = "exclusive file was created but its contents may be partial" } };
        if (create.mode) |mode|
            if (linux.errno(linux.fchmod(fd, @intCast(mode))) != .SUCCESS)
                return .{ .outcome = .{ .ambiguous = "file was created but its requested mode was not applied" } };
        const snapshot = try statFd(fd);
        const entry = self.mintEntry(root, parent.node, create.destination.name.bytes, snapshot) catch
            return .{ .outcome = .{ .ambiguous = "file was created but its result handle could not be retained" } };
        return .{ .outcome = .{ .applied = null }, .output = entry };
    }

    fn createDirectory(self: *LinuxFs, root: contract.Root, create: anytype, outputs: []?contract.EntryRef) contract.Error!Execution {
        try requireExclusive(create.expected);
        if (create.mode) |mode| try validateMode(mode);
        const name_z = try checkedNameZ(self.gpa, create.destination.name.bytes);
        defer self.gpa.free(name_z);
        var parent = try self.resolveParent(root, create.destination.parent, outputs);
        defer parent.close();
        const requested_mode = create.mode orelse 0o755;
        const initial_mode = if (create.mode != null) requested_mode | 0o700 else requested_mode;
        try voidResult(linux.mkdirat(parent.fd, name_z.ptr, @intCast(initial_mode)));
        if (create.mode) |mode| {
            const created_fd = openDirectoryAt(parent.fd, create.destination.name.bytes) catch
                return .{ .outcome = .{ .ambiguous = "directory was created but its requested mode could not be applied" } };
            defer closeFd(created_fd);
            if (linux.errno(linux.fchmod(created_fd, @intCast(mode))) != .SUCCESS)
                return .{ .outcome = .{ .ambiguous = "directory was created but its requested mode was not applied" } };
        }
        const snapshot = statAt(self.gpa, parent.fd, create.destination.name.bytes) catch
            return .{ .outcome = .{ .ambiguous = "directory was created but could not be observed" } };
        const entry = self.mintEntry(root, parent.node, create.destination.name.bytes, snapshot) catch
            return .{ .outcome = .{ .ambiguous = "directory was created but its result handle could not be retained" } };
        return .{ .outcome = .{ .applied = null }, .output = entry };
    }

    fn createSymlink(self: *LinuxFs, root: contract.Root, create: anytype, outputs: []?contract.EntryRef) contract.Error!Execution {
        try requireExclusive(create.expected);
        if (std.mem.indexOfScalar(u8, create.target, 0) != null) return error.InvalidName;
        const name_z = try checkedNameZ(self.gpa, create.destination.name.bytes);
        defer self.gpa.free(name_z);
        const target_z = try self.gpa.dupeZ(u8, create.target);
        defer self.gpa.free(target_z);
        var parent = try self.resolveParent(root, create.destination.parent, outputs);
        defer parent.close();
        try voidResult(linux.symlinkat(target_z.ptr, parent.fd, name_z.ptr));
        const snapshot = statAt(self.gpa, parent.fd, create.destination.name.bytes) catch
            return .{ .outcome = .{ .ambiguous = "symlink was created but could not be observed" } };
        const entry = self.mintEntry(root, parent.node, create.destination.name.bytes, snapshot) catch
            return .{ .outcome = .{ .ambiguous = "symlink was created but its result handle could not be retained" } };
        return .{ .outcome = .{ .applied = null }, .output = entry };
    }

    fn copy(self: *LinuxFs, destination_root: contract.Root, copy_op: anytype, outputs: []?contract.EntryRef) contract.Error!Execution {
        try requireExclusive(copy_op.expected);
        const source = switch (copy_op.source) {
            .entry => |entry| entry,
            .lease => |lease| return self.copyLease(destination_root, copy_op, outputs, lease),
        };
        const resolved = try self.resolveEntry(source.root, source.ref);
        defer resolved.close();
        if (!revisionMatches(resolved.snapshot, source.revision)) return error.Stale;
        if (resolved.snapshot.kind == .other) return error.Unsupported;
        var destination = try self.resolveParent(destination_root, copy_op.destination.parent, outputs);
        defer destination.close();
        const checked_destination = try checkedNameZ(self.gpa, copy_op.destination.name.bytes);
        self.gpa.free(checked_destination); // validation before any effect

        if (resolved.snapshot.kind == .directory) {
            const same_namespace = source.root.eql(destination_root) or
                (try self.rootState(source.root)).identity.locationEql((try self.rootState(destination_root)).identity);
            if (!same_namespace) return error.Unsupported;
            if (try self.wouldCycle(destination_root, resolved.snapshot.identity, destination.fd))
                return .{ .outcome = .{ .conflict = "cannot copy a directory inside itself" } };
        }

        self.copyAt(
            resolved.parent_fd,
            resolved.state.name,
            resolved.snapshot,
            destination.fd,
            copy_op.destination.name.bytes,
        ) catch |err| {
            if (err == error.Partial)
                return .{ .outcome = .{ .ambiguous = "recursive copy left an exclusive partial destination" } };
            return @as(contract.Error, @errorCast(err));
        };
        const copied = statAt(self.gpa, destination.fd, copy_op.destination.name.bytes) catch
            return .{ .outcome = .{ .ambiguous = "copy completed but its destination could not be observed" } };
        const entry = self.mintEntry(destination_root, destination.node, copy_op.destination.name.bytes, copied) catch
            return .{ .outcome = .{ .ambiguous = "copy completed but its result handle could not be retained" } };
        return .{ .outcome = .{ .applied = null }, .output = entry };
    }

    fn copyLease(
        self: *LinuxFs,
        destination_root: contract.Root,
        copy_op: anytype,
        outputs: []?contract.EntryRef,
        source: contract.LeaseSource,
    ) contract.Error!Execution {
        if (source.ref.authority != .here or source.ref.slot >= self.leases.items.len) return error.Stale;
        const slot = self.leases.items[source.ref.slot];
        if (slot.generation != source.ref.generation) return error.Stale;
        const lease = slot.value orelse return error.Stale;
        if (!lease.root.eql(source.root)) return error.Stale;
        if (lease.kind != .regular and lease.kind != .symlink) return error.Unsupported;
        try requireExclusive(copy_op.expected);
        var destination = try self.resolveParent(destination_root, copy_op.destination.parent, outputs);
        defer destination.close();
        const destination_z = try checkedNameZ(self.gpa, copy_op.destination.name.bytes);
        defer self.gpa.free(destination_z);
        switch (lease.kind) {
            .regular => {
                const fd = try fdResult(linux.openat(destination.fd, destination_z.ptr, .{
                    .ACCMODE = .WRONLY,
                    .CREAT = true,
                    .EXCL = true,
                    .NOFOLLOW = true,
                    .CLOEXEC = true,
                }, @intCast(lease.mode)));
                defer closeFd(fd);
                writeAll(fd, lease.contents) catch return .{ .outcome = .{ .ambiguous = "lease paste created a partial file" } };
                if (linux.errno(linux.fchmod(fd, @intCast(lease.mode))) != .SUCCESS)
                    return .{ .outcome = .{ .ambiguous = "lease paste created a file whose mode could not be applied" } };
            },
            .symlink => {
                const target_z = try self.gpa.dupeZ(u8, lease.link_target);
                defer self.gpa.free(target_z);
                try voidResult(linux.symlinkat(target_z.ptr, destination.fd, destination_z.ptr));
            },
            else => return error.Unsupported,
        }
        const copied = statAt(self.gpa, destination.fd, copy_op.destination.name.bytes) catch
            return .{ .outcome = .{ .ambiguous = "lease paste completed but its destination could not be observed" } };
        const entry = self.mintEntry(destination_root, destination.node, copy_op.destination.name.bytes, copied) catch
            return .{ .outcome = .{ .ambiguous = "lease paste completed but its result handle could not be retained" } };
        return .{ .outcome = .{ .applied = null }, .output = entry };
    }

    fn rename(self: *LinuxFs, destination_root: contract.Root, rename_op: anytype, outputs: []?contract.EntryRef) contract.Error!Execution {
        try requireExclusive(rename_op.expected);
        const source = try self.resolveEntry(rename_op.source.root, rename_op.source.ref);
        defer source.close();
        if (!revisionMatches(source.snapshot, rename_op.source.revision)) return error.Stale;
        var destination = try self.resolveParent(destination_root, rename_op.destination.parent, outputs);
        defer destination.close();
        const source_name_z = try checkedNameZ(self.gpa, source.state.name);
        defer self.gpa.free(source_name_z);
        const destination_name_z = try checkedNameZ(self.gpa, rename_op.destination.name.bytes);
        defer self.gpa.free(destination_name_z);

        const source_parent_snapshot = try statFd(source.parent_fd);
        const destination_parent_snapshot = try statFd(destination.fd);
        if (source_parent_snapshot.identity.locationEql(destination_parent_snapshot.identity) and
            std.mem.eql(u8, source.state.name, rename_op.destination.name.bytes)) return .{ .outcome = .already_satisfied };

        if (source.snapshot.kind == .directory) {
            const same_namespace = rename_op.source.root.eql(destination_root) or
                (try self.rootState(rename_op.source.root)).identity.locationEql((try self.rootState(destination_root)).identity);
            if (!same_namespace) return error.Unsupported;
            if (try self.wouldCycle(destination_root, source.snapshot.identity, destination.fd))
                return .{ .outcome = .{ .conflict = "cannot move a directory inside itself" } };
        }

        // Recheck after destination/cycle work, immediately before the effect.
        // Linux has no general compare-and-rename primitive, so this provider
        // truthfully advertises only preflight guard strength.
        const guarded = statAt(self.gpa, source.parent_fd, source.state.name) catch |err| switch (err) {
            error.NotFound => return error.Stale,
            else => return err,
        };
        if (!guarded.identity.eql(source.snapshot.identity) or
            !revisionMatches(guarded, rename_op.source.revision)) return error.Stale;
        try renameNoReplace(source.parent_fd, source_name_z.ptr, destination.fd, destination_name_z.ptr);
        const moved = statAt(self.gpa, destination.fd, rename_op.destination.name.bytes) catch
            return .{ .outcome = .{ .ambiguous = "rename succeeded but the destination immediately changed" } };
        if (!moved.identity.eql(source.snapshot.identity))
            return .{ .outcome = .{ .ambiguous = "rename raced with replacement of the guarded source" } };

        self.invalidateEntry(rename_op.source.ref);
        const entry = self.mintEntry(destination_root, destination.node, rename_op.destination.name.bytes, moved) catch
            return .{ .outcome = .{ .ambiguous = "rename completed but its result handle could not be retained" } };
        return .{ .outcome = .{ .applied = null }, .output = entry };
    }

    fn remove(self: *LinuxFs, remove_op: anytype) contract.Error!Execution {
        if (remove_op.policy == .quarantine) return error.Unsupported;
        const source = try self.resolveEntry(remove_op.source.root, remove_op.source.ref);
        defer source.close();
        if (!revisionMatches(source.snapshot, remove_op.source.revision)) return error.Stale;
        self.removeAt(source.parent_fd, source.state.name, source.snapshot) catch |err| {
            if (err == error.Partial)
                return .{ .outcome = .{ .ambiguous = "permanent recursive removal was only partially completed" } };
            return @as(contract.Error, @errorCast(err));
        };
        self.invalidateEntry(remove_op.source.ref);
        return .{ .outcome = .{ .applied = null } };
    }

    fn setPermissions(self: *LinuxFs, set: anytype) contract.Error!Execution {
        // Following a symlink is an explicit contract request but not a
        // capability this provider advertises in its first slice.
        if (set.follow_symlink) return error.Unsupported;
        try validateMode(set.mode);
        const source = try self.resolveEntry(set.source.root, set.source.ref);
        defer source.close();
        if (!revisionMatches(source.snapshot, set.source.revision)) return error.Stale;
        if (source.snapshot.kind == .symlink) return error.Unsupported;
        if (source.snapshot.mode == set.mode) return .{ .outcome = .already_satisfied };
        const name_z = try checkedNameZ(self.gpa, source.state.name);
        defer self.gpa.free(name_z);
        const guarded = statAt(self.gpa, source.parent_fd, source.state.name) catch |err| switch (err) {
            error.NotFound => return error.Stale,
            else => return err,
        };
        if (!guarded.identity.eql(source.snapshot.identity) or
            !revisionMatches(guarded, set.source.revision)) return error.Stale;
        const chmod_rc = linux.fchmodat2(source.parent_fd, name_z.ptr, @intCast(set.mode), linux.AT.SYMLINK_NOFOLLOW);
        switch (linux.errno(chmod_rc)) {
            .SUCCESS => {},
            .NOSYS, .INVAL, .OPNOTSUPP => {
                const flags: linux.O = if (source.snapshot.kind == .directory)
                    .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }
                else
                    .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true };
                const fd = try fdResult(linux.openat(source.parent_fd, name_z.ptr, flags, 0));
                defer closeFd(fd);
                const opened = try statFd(fd);
                if (!opened.identity.eql(source.snapshot.identity) or
                    !revisionMatches(opened, set.source.revision)) return error.Stale;
                switch (linux.errno(linux.fchmod(fd, @intCast(set.mode)))) {
                    .SUCCESS => {},
                    .ACCES, .PERM => return error.PermissionDenied,
                    else => return error.Unsupported,
                }
            },
            .NOENT => return error.Stale,
            .ACCES, .PERM => return error.PermissionDenied,
            .LOOP => return error.Confined,
            else => return error.Io,
        }
        const finish = statAt(self.gpa, source.parent_fd, source.state.name) catch
            return .{ .outcome = .{ .ambiguous = "permissions changed but the entry immediately disappeared" } };
        if (!finish.identity.eql(source.snapshot.identity))
            return .{ .outcome = .{ .ambiguous = "permission change raced with entry replacement" } };
        return .{ .outcome = .{ .applied = null } };
    }

    fn copyAt(
        self: *LinuxFs,
        source_parent_fd: i32,
        source_name: []const u8,
        expected: Snapshot,
        destination_parent_fd: i32,
        destination_name: []const u8,
    ) CopyError!void {
        const source_z = try checkedNameZ(self.gpa, source_name);
        defer self.gpa.free(source_z);
        const destination_z = try checkedNameZ(self.gpa, destination_name);
        defer self.gpa.free(destination_z);

        switch (expected.kind) {
            .regular => {
                const source_rc = linux.openat(source_parent_fd, source_z.ptr, .{
                    .ACCMODE = .RDONLY,
                    .CLOEXEC = true,
                    .NOFOLLOW = true,
                }, 0);
                const source_fd = try fdResult(source_rc);
                defer closeFd(source_fd);
                const opened = try statFd(source_fd);
                if (!opened.identity.eql(expected.identity) or !sameRevision(opened, expected)) return error.Stale;
                const destination_rc = linux.openat(destination_parent_fd, destination_z.ptr, .{
                    .ACCMODE = .WRONLY,
                    .CREAT = true,
                    .EXCL = true,
                    .NOFOLLOW = true,
                    .CLOEXEC = true,
                }, @intCast(expected.mode));
                const destination_fd = try fdResult(destination_rc);
                defer closeFd(destination_fd);
                var buffer: [64 * 1024]u8 = undefined;
                while (true) {
                    const read_rc = linux.read(source_fd, &buffer, buffer.len);
                    const count = switch (linux.errno(read_rc)) {
                        .SUCCESS => read_rc,
                        .INTR => continue,
                        else => return error.Partial,
                    };
                    if (count == 0) break;
                    writeAll(destination_fd, buffer[0..count]) catch return error.Partial;
                }
                if (linux.errno(linux.fchmod(destination_fd, @intCast(expected.mode))) != .SUCCESS) return error.Partial;
                const finish = try statFd(source_fd);
                if (!finish.identity.eql(expected.identity) or !sameRevision(finish, expected)) return error.Partial;
            },
            .directory => {
                const source_rc = linux.openat(source_parent_fd, source_z.ptr, .{
                    .ACCMODE = .RDONLY,
                    .DIRECTORY = true,
                    .CLOEXEC = true,
                    .NOFOLLOW = true,
                }, 0);
                const source_fd = try fdResult(source_rc);
                defer closeFd(source_fd);
                const opened = try statFd(source_fd);
                if (!opened.identity.eql(expected.identity) or !sameRevision(opened, expected)) return error.Stale;
                // Keep the provider able to populate a directory whose final
                // mode intentionally removes owner traversal/read access.
                try voidResult(linux.mkdirat(destination_parent_fd, destination_z.ptr, @intCast(expected.mode | 0o700)));
                const destination_rc = linux.openat(destination_parent_fd, destination_z.ptr, .{
                    .ACCMODE = .RDONLY,
                    .DIRECTORY = true,
                    .CLOEXEC = true,
                    .NOFOLLOW = true,
                }, 0);
                const destination_fd = fdResult(destination_rc) catch return error.Partial;
                defer closeFd(destination_fd);
                var buffer: [16 * 1024]u8 align(@alignOf(linux.dirent64)) = undefined;
                while (true) {
                    const dents_rc = linux.getdents64(source_fd, &buffer, buffer.len);
                    const bytes_read = switch (linux.errno(dents_rc)) {
                        .SUCCESS => dents_rc,
                        .INTR => continue,
                        else => return error.Partial,
                    };
                    if (bytes_read == 0) break;
                    var offset: usize = 0;
                    while (offset < bytes_read) {
                        const dirent: *align(1) const linux.dirent64 = @ptrCast(&buffer[offset]);
                        if (dirent.reclen == 0 or offset + dirent.reclen > bytes_read) return error.Partial;
                        const child_z: [*:0]const u8 = @ptrCast(&buffer[offset + @offsetOf(linux.dirent64, "name")]);
                        const child = std.mem.span(child_z);
                        offset += dirent.reclen;
                        if (std.mem.eql(u8, child, ".") or std.mem.eql(u8, child, "..")) continue;
                        const child_snapshot = statAt(self.gpa, source_fd, child) catch return error.Partial;
                        self.copyAt(source_fd, child, child_snapshot, destination_fd, child) catch return error.Partial;
                    }
                }
                if (linux.errno(linux.fchmod(destination_fd, @intCast(expected.mode))) != .SUCCESS) return error.Partial;
                const finish = try statFd(source_fd);
                if (!finish.identity.eql(expected.identity) or !sameRevision(finish, expected)) return error.Partial;
            },
            .symlink => {
                const target = try readlinkAt(self.gpa, source_parent_fd, source_name);
                defer self.gpa.free(target);
                const finish = try statAt(self.gpa, source_parent_fd, source_name);
                if (!finish.identity.eql(expected.identity) or !sameRevision(finish, expected)) return error.Stale;
                if (std.mem.indexOfScalar(u8, target, 0) != null) return error.InvalidName;
                const target_z = try self.gpa.dupeZ(u8, target);
                defer self.gpa.free(target_z);
                try voidResult(linux.symlinkat(target_z.ptr, destination_parent_fd, destination_z.ptr));
            },
            .other => return error.Unsupported,
        }
    }

    fn removeAt(self: *LinuxFs, parent_fd: i32, name: []const u8, expected: Snapshot) RemoveError!void {
        const name_z = try checkedNameZ(self.gpa, name);
        defer self.gpa.free(name_z);
        if (expected.kind != .directory) {
            const current = try statAt(self.gpa, parent_fd, name);
            if (!current.identity.eql(expected.identity) or !sameRevision(current, expected)) return error.Stale;
            try voidResult(linux.unlinkat(parent_fd, name_z.ptr, 0));
            return;
        }

        const open_rc = linux.openat(parent_fd, name_z.ptr, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, 0);
        const directory_fd = try fdResult(open_rc);
        defer closeFd(directory_fd);
        const opened = try statFd(directory_fd);
        if (!opened.identity.eql(expected.identity) or !sameRevision(opened, expected)) return error.Stale;

        var changed = false;
        var buffer: [16 * 1024]u8 align(@alignOf(linux.dirent64)) = undefined;
        while (true) {
            const dents_rc = linux.getdents64(directory_fd, &buffer, buffer.len);
            const bytes_read = switch (linux.errno(dents_rc)) {
                .SUCCESS => dents_rc,
                .INTR => continue,
                else => return if (changed) error.Partial else error.Io,
            };
            if (bytes_read == 0) break;
            var offset: usize = 0;
            var restart = false;
            while (offset < bytes_read) {
                const dirent: *align(1) const linux.dirent64 = @ptrCast(&buffer[offset]);
                if (dirent.reclen == 0 or offset + dirent.reclen > bytes_read) return error.Partial;
                const child_z: [*:0]const u8 = @ptrCast(&buffer[offset + @offsetOf(linux.dirent64, "name")]);
                const child = std.mem.span(child_z);
                offset += dirent.reclen;
                if (std.mem.eql(u8, child, ".") or std.mem.eql(u8, child, "..")) continue;
                const child_snapshot = statAt(self.gpa, directory_fd, child) catch return if (changed) error.Partial else error.Io;
                self.removeAt(directory_fd, child, child_snapshot) catch return error.Partial;
                changed = true;
                // Directory cookies may be invalidated by deletion. Restart
                // after each child so no entry is skipped by a shifted cookie.
                restart = true;
                break;
            }
            if (restart) {
                if (linux.errno(linux.lseek(directory_fd, 0, linux.SEEK.SET)) != .SUCCESS) return error.Partial;
                continue;
            }
        }
        // Children changed the directory revision, so the final guard is its
        // opaque identity rather than the original revision we changed.
        const current = statAt(self.gpa, parent_fd, name) catch return error.Partial;
        if (!current.identity.eql(expected.identity)) return error.Partial;
        voidResult(linux.unlinkat(parent_fd, name_z.ptr, linux.AT.REMOVEDIR)) catch return error.Partial;
    }

    fn resolveParent(
        self: *LinuxFs,
        root: contract.Root,
        parent: contract.ParentRef,
        outputs: []?contract.EntryRef,
    ) contract.Error!ResolvedDirectory {
        const node: contract.NodeRef = switch (parent) {
            .root => .root,
            .entry => |entry| .{ .entry = entry },
            .planned => |index| .{ .entry = if (index < outputs.len) outputs[index] orelse return error.Stale else return error.Stale },
        };
        return self.resolveDirectory(root, node);
    }

    fn resolveDirectory(self: *LinuxFs, root: contract.Root, node: contract.NodeRef) contract.Error!ResolvedDirectory {
        return switch (node) {
            .root => blk: {
                const state = try self.rootState(root);
                const fd = try openDirectoryAt(state.fd, ".");
                errdefer closeFd(fd);
                const snapshot = try statFd(fd);
                if (!snapshot.identity.locationEql(state.identity)) return error.Stale;
                break :blk .{ .fd = fd, .node = .root, .snapshot = snapshot };
            },
            .entry => |entry| blk: {
                const resolved = try self.resolveEntry(root, entry);
                defer resolved.close();
                if (resolved.snapshot.kind != .directory) return error.NotDirectory;
                const fd = try openDirectoryAt(resolved.parent_fd, resolved.state.name);
                errdefer closeFd(fd);
                const snapshot = try statFd(fd);
                if (!snapshot.identity.eql(resolved.snapshot.identity)) return error.Stale;
                break :blk .{ .fd = fd, .node = .{ .entry = entry }, .snapshot = snapshot };
            },
        };
    }

    fn resolveEntry(self: *LinuxFs, root: contract.Root, entry: contract.EntryRef) contract.Error!ResolvedEntry {
        _ = try self.rootState(root);
        const state = try self.entryState(entry);
        if (!state.root.eql(root)) return error.Stale;
        var parent = try self.resolveDirectory(root, state.parent);
        errdefer parent.close();
        const snapshot = statAt(self.gpa, parent.fd, state.name) catch |err| switch (err) {
            error.NotFound => return error.Stale,
            else => return err,
        };
        if (!snapshot.identity.eql(state.identity)) return error.Stale;
        return .{ .parent_fd = parent.fd, .state = state, .snapshot = snapshot };
    }

    fn wouldCycle(self: *LinuxFs, root: contract.Root, source: Identity, destination_fd: i32) contract.Error!bool {
        const root_identity = (try self.rootState(root)).identity;
        var current_fd = try openDirectoryAt(destination_fd, ".");
        defer closeFd(current_fd);
        while (true) {
            const current = try statFd(current_fd);
            if (current.identity.eql(source)) return true;
            if (current.identity.locationEql(root_identity)) return false;
            const parent_fd = try openDirectoryAt(current_fd, "..");
            const parent = try statFd(parent_fd);
            if (parent.identity.locationEql(current.identity)) {
                closeFd(parent_fd);
                return error.Confined;
            }
            closeFd(current_fd);
            current_fd = parent_fd;
        }
    }

    fn observation(
        self: *LinuxFs,
        arena: std.mem.Allocator,
        node: contract.NodeRef,
        snapshot: Snapshot,
        parent_fd: ?i32,
        name: ?[]const u8,
    ) contract.Error!contract.Observation {
        const link_target = if (snapshot.kind == .symlink)
            try self.captureLinkTarget(arena, parent_fd orelse return error.Io, name orelse return error.Io, snapshot)
        else
            null;
        return self.observationValue(arena, node, snapshot, link_target);
    }

    fn captureLinkTarget(
        self: *LinuxFs,
        arena: std.mem.Allocator,
        parent_fd: i32,
        name: []const u8,
        snapshot: Snapshot,
    ) contract.Error!?[]const u8 {
        if (snapshot.kind != .symlink) return null;
        const target = try readlinkAt(self.gpa, parent_fd, name);
        defer self.gpa.free(target);
        const finish = statAt(self.gpa, parent_fd, name) catch |err| switch (err) {
            error.NotFound => return error.Stale,
            else => return err,
        };
        if (!finish.identity.eql(snapshot.identity) or !sameRevision(finish, snapshot)) return error.Stale;
        return try arena.dupe(u8, target);
    }

    fn observationValue(
        self: *LinuxFs,
        arena: std.mem.Allocator,
        node: contract.NodeRef,
        snapshot: Snapshot,
        link_target: ?[]const u8,
    ) contract.Error!contract.Observation {
        const revision_bytes = revisionBytes(&snapshot);
        const token = try arena.dupe(u8, &revision_bytes);
        return self.observationWithRevision(node, snapshot, link_target, token);
    }

    fn observationWithRevision(
        self: *LinuxFs,
        node: contract.NodeRef,
        snapshot: Snapshot,
        link_target: ?[]const u8,
        revision_token: []const u8,
    ) contract.Observation {
        _ = self;
        return .{
            .node = node,
            .revision = .{ .token = revision_token },
            .kind = snapshot.kind,
            .metadata = .{
                .mode = snapshot.mode,
                .size = snapshot.size,
                .modified_ns = @as(i128, snapshot.modified_sec) * std.time.ns_per_s + snapshot.modified_nsec,
                .link_target = link_target,
            },
        };
    }

    /// Reconcile only after a directory snapshot has been proven stable.
    /// Every allocation happens before invalidation, so allocation failure or
    /// a stale listing leaves the registry untouched.
    fn reconcileDirectory(
        self: *LinuxFs,
        scratch: std.mem.Allocator,
        root: contract.Root,
        parent: contract.NodeRef,
        pending: []const PendingEntry,
    ) contract.Error![]contract.EntryRef {
        const refs = try scratch.alloc(contract.EntryRef, pending.len);
        const matched = try scratch.alloc(bool, pending.len);
        @memset(matched, false);
        const prepared_names = try scratch.alloc(?[]u8, pending.len);
        @memset(prepared_names, null);
        errdefer for (prepared_names) |prepared|
            if (prepared) |name| self.gpa.free(name);

        var pending_by_name: std.StringHashMapUnmanaged(usize) = .empty;
        defer pending_by_name.deinit(scratch);
        for (pending, 0..) |candidate, index| {
            const result = try pending_by_name.getOrPut(scratch, candidate.name);
            if (result.found_existing) return error.Io;
            result.value_ptr.* = index;
        }

        var invalid: std.ArrayList(contract.EntryRef) = .empty;
        for (self.entries.items, 0..) |slot, slot_index| {
            const state = slot.value orelse continue;
            if (!state.root.eql(root) or !nodeEql(state.parent, parent)) continue;
            const pending_index = pending_by_name.get(state.name);
            if (pending_index) |index| {
                if (!matched[index] and state.identity.eql(pending[index].snapshot.identity)) {
                    refs[index] = .{
                        .authority = .here,
                        .slot = @intCast(slot_index),
                        .generation = slot.generation,
                    };
                    matched[index] = true;
                    continue;
                }
            }
            try invalid.append(scratch, .{
                .authority = .here,
                .slot = @intCast(slot_index),
                .generation = slot.generation,
            });
        }

        var new_count: usize = 0;
        for (pending, matched, prepared_names) |candidate, is_matched, *prepared| {
            if (is_matched) continue;
            prepared.* = try self.gpa.dupe(u8, candidate.name);
            new_count += 1;
        }
        var reusable_slots = invalid.items.len;
        for (self.entries.items) |slot|
            if (slot.value == null) {
                reusable_slots += 1;
            };
        // Reserve only the append tail that cannot reuse an existing slot.
        // The commit phase must contain no fallible allocation, but ordinary
        // same-size churn must not silently double registry capacity.
        const append_count = new_count -| reusable_slots;
        try self.entries.ensureUnusedCapacity(self.gpa, append_count);

        for (invalid.items) |entry| self.invalidateEntry(entry);
        for (pending, matched, prepared_names, 0..) |candidate, is_matched, *prepared, index| {
            if (is_matched) continue;
            const owned_name = prepared.*.?;
            refs[index] = self.insertPreparedEntry(root, parent, owned_name, candidate.snapshot);
            prepared.* = null;
        }
        for (pending, matched, refs) |candidate, is_matched, entry| {
            if (!is_matched) continue;
            self.entries.items[entry.slot].value.?.revision = revisionBytes(&candidate.snapshot);
        }
        return refs;
    }

    fn insertPreparedEntry(
        self: *LinuxFs,
        root: contract.Root,
        parent: contract.NodeRef,
        owned_name: []u8,
        snapshot: Snapshot,
    ) contract.EntryRef {
        for (self.entries.items, 0..) |*slot, index| {
            if (slot.value != null) continue;
            slot.value = .{
                .root = root,
                .parent = parent,
                .name = owned_name,
                .identity = snapshot.identity,
                .revision = revisionBytes(&snapshot),
            };
            return .{ .authority = .here, .slot = @intCast(index), .generation = slot.generation };
        }
        self.entries.appendAssumeCapacity(.{
            .generation = self.generation_seed,
            .value = .{
                .root = root,
                .parent = parent,
                .name = owned_name,
                .identity = snapshot.identity,
                .revision = revisionBytes(&snapshot),
            },
        });
        return .{
            .authority = .here,
            .slot = @intCast(self.entries.items.len - 1),
            .generation = self.entries.items[self.entries.items.len - 1].generation,
        };
    }

    fn mintEntry(
        self: *LinuxFs,
        root: contract.Root,
        parent: contract.NodeRef,
        name: []const u8,
        snapshot: Snapshot,
    ) contract.Error!contract.EntryRef {
        _ = contract.Name.init(name) catch return error.InvalidName;
        for (self.entries.items, 0..) |*slot, index| {
            const state = if (slot.value) |*value| value else continue;
            if (!state.root.eql(root) or !nodeEql(state.parent, parent) or !std.mem.eql(u8, state.name, name)) continue;
            if (state.identity.eql(snapshot.identity)) {
                state.revision = revisionBytes(&snapshot);
                return .{
                    .authority = .here,
                    .slot = @intCast(index),
                    .generation = slot.generation,
                };
            }
            self.clearEntrySlot(slot);
        }
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        for (self.entries.items, 0..) |*slot, index| {
            if (slot.value != null) continue;
            slot.value = .{
                .root = root,
                .parent = parent,
                .name = owned_name,
                .identity = snapshot.identity,
                .revision = revisionBytes(&snapshot),
            };
            return .{ .authority = .here, .slot = @intCast(index), .generation = slot.generation };
        }
        try self.entries.append(self.gpa, .{
            .generation = self.generation_seed,
            .value = .{
                .root = root,
                .parent = parent,
                .name = owned_name,
                .identity = snapshot.identity,
                .revision = revisionBytes(&snapshot),
            },
        });
        return .{
            .authority = .here,
            .slot = @intCast(self.entries.items.len - 1),
            .generation = self.entries.items[self.entries.items.len - 1].generation,
        };
    }

    fn invalidateEntry(self: *LinuxFs, entry: contract.EntryRef) void {
        if (entry.authority != .here or entry.slot >= self.entries.items.len) return;
        const slot = &self.entries.items[entry.slot];
        if (slot.generation != entry.generation or slot.value == null) return;
        var index: usize = 0;
        while (index < self.entries.items.len) : (index += 1) {
            const child_slot = &self.entries.items[index];
            const child = if (child_slot.value) |*value| value else continue;
            const is_child = switch (child.parent) {
                .root => false,
                .entry => |parent| parent.eql(entry),
            };
            if (is_child) self.invalidateEntry(.{
                .authority = .here,
                .slot = @intCast(index),
                .generation = child_slot.generation,
            });
        }
        self.clearEntrySlot(slot);
    }

    fn clearEntrySlot(self: *LinuxFs, slot: *EntrySlot) void {
        if (slot.value) |entry| {
            self.gpa.free(entry.name);
        }
        slot.value = null;
        bumpGeneration(&slot.generation);
    }

    fn clearLeaseSlot(self: *LinuxFs, slot: *LeaseSlot) void {
        if (slot.value) |lease| {
            self.gpa.free(lease.contents);
            self.gpa.free(lease.link_target);
        }
        slot.value = null;
        bumpGeneration(&slot.generation);
    }

    fn rootSlot(self: *LinuxFs, root: contract.Root) ?*RootSlot {
        if (root.authority != .here or root.slot >= self.roots.items.len) return null;
        const slot = &self.roots.items[root.slot];
        if (slot.generation != root.generation) return null;
        return slot;
    }

    fn rootState(self: *LinuxFs, root: contract.Root) contract.Error!*RootState {
        const slot = self.rootSlot(root) orelse return error.Stale;
        return if (slot.value) |*value| value else error.Stale;
    }

    fn entryState(self: *LinuxFs, entry: contract.EntryRef) contract.Error!*EntryState {
        if (entry.authority != .here or entry.slot >= self.entries.items.len) return error.Stale;
        const slot = &self.entries.items[entry.slot];
        if (slot.generation != entry.generation) return error.Stale;
        return if (slot.value) |*value| value else error.Stale;
    }
};

fn nodeEql(a: contract.NodeRef, b: contract.NodeRef) bool {
    return switch (a) {
        .root => b == .root,
        .entry => |entry| switch (b) {
            .root => false,
            .entry => |other| entry.eql(other),
        },
    };
}

fn bumpGeneration(generation: *u32) void {
    generation.* +%= 1;
    if (generation.* == 0) generation.* = 1;
}

fn outcomeForError(err: contract.Error) contract.Outcome {
    return switch (err) {
        error.NotFound, error.Stale => .stale,
        error.AlreadyExists => .{ .conflict = "destination exists" },
        error.NotDirectory => .{ .conflict = "parent is not a directory" },
        error.PermissionDenied => .{ .conflict = "permission denied" },
        error.Confined => .{ .conflict = "operation escaped its acquired root" },
        error.CrossDevice => .{ .conflict = "cross-device operation is unsupported" },
        error.Unsupported => .unsupported,
        error.InvalidName => .{ .conflict = "invalid raw leaf name" },
        error.LimitExceeded => .{ .conflict = "lease size limit exceeded" },
        error.Busy => .{ .conflict = "entry is busy" },
        error.Io => .{ .ambiguous = "filesystem operation failed with unknown effect" },
        error.OutOfMemory => unreachable,
    };
}

fn requireExclusive(expected: contract.Expected) contract.Error!void {
    switch (expected) {
        .absent, .anything => {},
        .entry => return error.Unsupported,
    }
}

fn validateMode(mode: u32) contract.Error!void {
    if (mode & ~@as(u32, 0o7777) != 0) return error.InvalidName;
}

fn checkedNameZ(gpa: std.mem.Allocator, bytes: []const u8) contract.Error![:0]u8 {
    _ = contract.Name.init(bytes) catch return error.InvalidName;
    return gpa.dupeZ(u8, bytes);
}

fn readWholeFile(
    gpa: std.mem.Allocator,
    parent_fd: i32,
    name: []const u8,
    expected: LinuxFs.Snapshot,
    max_bytes: u64,
) contract.Error![]u8 {
    const name_z = try checkedNameZ(gpa, name);
    defer gpa.free(name_z);
    const fd = try fdResult(linux.openat(parent_fd, name_z.ptr, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, 0));
    defer closeFd(fd);
    const opened = try statFd(fd);
    if (opened.kind != .regular or !opened.identity.eql(expected.identity) or !sameRevision(opened, expected)) return error.Stale;
    if (opened.size > max_bytes) return error.LimitExceeded;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const remaining = max_bytes -| bytes.items.len;
        if (remaining == 0) {
            const probe = linux.read(fd, &buffer, 1);
            switch (linux.errno(probe)) {
                .SUCCESS => if (probe != 0) return error.LimitExceeded,
                .INTR => continue,
                .ACCES, .PERM => return error.PermissionDenied,
                else => return error.Io,
            }
            break;
        }
        const rc = linux.read(fd, &buffer, @intCast(@min(remaining, buffer.len)));
        const count = switch (linux.errno(rc)) {
            .SUCCESS => rc,
            .INTR => continue,
            .ACCES, .PERM => return error.PermissionDenied,
            else => return error.Io,
        };
        if (count == 0) break;
        try bytes.appendSlice(gpa, buffer[0..count]);
    }
    const finish = try statFd(fd);
    if (!finish.identity.eql(expected.identity) or !sameRevision(finish, expected)) return error.Stale;
    return bytes.toOwnedSlice(gpa);
}

fn readlinkAtBounded(
    gpa: std.mem.Allocator,
    parent_fd: i32,
    name: []const u8,
    max_bytes: u64,
) contract.Error![]u8 {
    const name_z = try checkedNameZ(gpa, name);
    defer gpa.free(name_z);
    const capacity = std.math.cast(usize, max_bytes +| 1) orelse return error.LimitExceeded;
    const buffer = try gpa.alloc(u8, capacity);
    errdefer gpa.free(buffer);
    var length: usize = undefined;
    while (true) {
        const rc = linux.readlinkat(parent_fd, name_z.ptr, buffer.ptr, buffer.len);
        length = switch (linux.errno(rc)) {
            .SUCCESS => rc,
            .INTR => continue,
            .NOENT => return error.NotFound,
            .ACCES, .PERM => return error.PermissionDenied,
            .LOOP => return error.Confined,
            else => return error.Io,
        };
        break;
    }
    if (length > max_bytes) return error.LimitExceeded;
    return gpa.realloc(buffer, length);
}

fn openDirectoryAt(parent_fd: i32, name: []const u8) contract.Error!i32 {
    var buffer: [4096:0]u8 = undefined;
    if (name.len >= buffer.len) return error.InvalidName;
    @memcpy(buffer[0..name.len], name);
    buffer[name.len] = 0;
    return fdResult(linux.openat(parent_fd, &buffer, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, 0));
}

fn statAt(gpa: std.mem.Allocator, parent_fd: i32, name: []const u8) contract.Error!LinuxFs.Snapshot {
    const name_z = try checkedNameZ(gpa, name);
    defer gpa.free(name_z);
    return statxAt(parent_fd, name_z.ptr, linux.AT.SYMLINK_NOFOLLOW | linux.AT.NO_AUTOMOUNT);
}

fn statFd(fd: i32) contract.Error!LinuxFs.Snapshot {
    return statxAt(fd, "", linux.AT.EMPTY_PATH | linux.AT.SYMLINK_NOFOLLOW | linux.AT.NO_AUTOMOUNT);
}

fn statxAt(fd: i32, name: [*:0]const u8, flags: u32) contract.Error!LinuxFs.Snapshot {
    var stat: linux.Statx = undefined;
    var mask = linux.STATX.BASIC_STATS;
    mask.MNT_ID = true;
    mask.BTIME = true;
    const rc = linux.statx(fd, name, flags, mask, &stat);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOENT => return error.NotFound,
        .NOTDIR => return error.NotDirectory,
        .ACCES, .PERM => return error.PermissionDenied,
        .LOOP, .XDEV => return error.Confined,
        .AGAIN, .BUSY => return error.Busy,
        else => return error.Io,
    }
    const file_type = stat.mode & linux.S.IFMT;
    const kind: contract.Kind = if (file_type == linux.S.IFREG)
        .regular
    else if (file_type == linux.S.IFDIR)
        .directory
    else if (file_type == linux.S.IFLNK)
        .symlink
    else
        .other;
    return .{
        .identity = .{
            .dev_major = stat.dev_major,
            .dev_minor = stat.dev_minor,
            .mount_id = if (stat.mask.MNT_ID) stat.mnt_id else 0,
            .inode = stat.ino,
            .has_birth_time = stat.mask.BTIME,
            .birth_sec = if (stat.mask.BTIME) stat.btime.sec else 0,
            .birth_nsec = if (stat.mask.BTIME) stat.btime.nsec else 0,
        },
        .kind = kind,
        .mode = stat.mode & 0o7777,
        .size = stat.size,
        .nlink = stat.nlink,
        .modified_sec = stat.mtime.sec,
        .modified_nsec = stat.mtime.nsec,
        .changed_sec = stat.ctime.sec,
        .changed_nsec = stat.ctime.nsec,
    };
}

fn revisionBytes(snapshot: *const LinuxFs.Snapshot) [revision_len]u8 {
    var bytes = [_]u8{0} ** revision_len;
    std.mem.writeInt(u32, bytes[0..4], revision_magic, .little);
    std.mem.writeInt(u32, bytes[4..8], snapshot.identity.dev_major, .little);
    std.mem.writeInt(u32, bytes[8..12], snapshot.identity.dev_minor, .little);
    std.mem.writeInt(u64, bytes[12..20], snapshot.identity.mount_id, .little);
    std.mem.writeInt(u64, bytes[20..28], snapshot.identity.inode, .little);
    std.mem.writeInt(u32, bytes[28..32], @intFromBool(snapshot.identity.has_birth_time), .little);
    std.mem.writeInt(u64, bytes[32..40], @bitCast(snapshot.identity.birth_sec), .little);
    std.mem.writeInt(u32, bytes[40..44], snapshot.identity.birth_nsec, .little);
    std.mem.writeInt(u32, bytes[44..48], snapshot.mode, .little);
    std.mem.writeInt(u64, bytes[48..56], snapshot.size, .little);
    std.mem.writeInt(u32, bytes[56..60], snapshot.nlink, .little);
    std.mem.writeInt(u64, bytes[60..68], @bitCast(snapshot.modified_sec), .little);
    std.mem.writeInt(u32, bytes[68..72], snapshot.modified_nsec, .little);
    std.mem.writeInt(u64, bytes[72..80], @bitCast(snapshot.changed_sec), .little);
    std.mem.writeInt(u32, bytes[80..84], snapshot.changed_nsec, .little);
    std.mem.writeInt(u32, bytes[84..88], @intFromEnum(snapshot.kind), .little);
    return bytes;
}

fn revisionMatches(snapshot: LinuxFs.Snapshot, revision: contract.Revision) bool {
    const actual = revisionBytes(&snapshot);
    return std.mem.eql(u8, &actual, revision.token);
}

fn sameRevision(a: LinuxFs.Snapshot, b: LinuxFs.Snapshot) bool {
    const a_bytes = revisionBytes(&a);
    const b_bytes = revisionBytes(&b);
    return std.mem.eql(u8, &a_bytes, &b_bytes);
}

fn readlinkAt(gpa: std.mem.Allocator, parent_fd: i32, name: []const u8) contract.Error![]u8 {
    const name_z = try checkedNameZ(gpa, name);
    defer gpa.free(name_z);
    var capacity: usize = 256;
    while (capacity <= 1024 * 1024) : (capacity *= 2) {
        const buffer = try gpa.alloc(u8, capacity);
        const rc = linux.readlinkat(parent_fd, name_z.ptr, buffer.ptr, buffer.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc < buffer.len) {
                    const resized = gpa.realloc(buffer, rc) catch |err| {
                        // realloc is allowed to leave the original allocation
                        // live when it cannot resize or move it. This buffer
                        // is owned by this helper, so release it before
                        // propagating OOM rather than leaking on a long link.
                        gpa.free(buffer);
                        return err;
                    };
                    return resized;
                }
                gpa.free(buffer);
            },
            .NOENT => {
                gpa.free(buffer);
                return error.NotFound;
            },
            .ACCES, .PERM => {
                gpa.free(buffer);
                return error.PermissionDenied;
            },
            .INVAL => {
                gpa.free(buffer);
                return error.Unsupported;
            },
            else => {
                gpa.free(buffer);
                return error.Io;
            },
        }
    }
    return error.Io;
}

fn writeAll(fd: i32, bytes: []const u8) contract.Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        const count = switch (linux.errno(rc)) {
            .SUCCESS => rc,
            .INTR => continue,
            .ACCES, .PERM => return error.PermissionDenied,
            else => return error.Io,
        };
        if (count == 0) return error.Io;
        offset += count;
    }
}

fn renameNoReplace(old_fd: i32, old_name: [*:0]const u8, new_fd: i32, new_name: [*:0]const u8) contract.Error!void {
    const rc = linux.renameat2(old_fd, old_name, new_fd, new_name, .{ .NOREPLACE = true });
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .EXIST, .NOTEMPTY => return error.AlreadyExists,
        .NOENT => return error.Stale,
        .NOTDIR, .ISDIR => return error.NotDirectory,
        .ACCES, .PERM => return error.PermissionDenied,
        .XDEV => return error.CrossDevice,
        .LOOP => return error.Confined,
        .BUSY => return error.Busy,
        .NOSYS, .INVAL => return error.Unsupported,
        else => return error.Io,
    }
}

fn fdResult(rc: usize) contract.Error!i32 {
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .NOENT => error.NotFound,
        .EXIST => error.AlreadyExists,
        .NOTDIR, .ISDIR => error.NotDirectory,
        .ACCES, .PERM => error.PermissionDenied,
        .XDEV, .LOOP => error.Confined,
        .BUSY, .AGAIN => error.Busy,
        else => error.Io,
    };
}

fn voidResult(rc: usize) contract.Error!void {
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOENT => return error.NotFound,
        .EXIST, .NOTEMPTY => return error.AlreadyExists,
        .NOTDIR, .ISDIR => return error.NotDirectory,
        .ACCES, .PERM => return error.PermissionDenied,
        .XDEV => return error.CrossDevice,
        .LOOP => return error.Confined,
        .BUSY, .AGAIN => return error.Busy,
        .NOSYS, .OPNOTSUPP => return error.Unsupported,
        else => return error.Io,
    }
}

fn closeFd(fd: i32) void {
    // On Linux the descriptor is released even when close reports EINTR;
    // retrying could close an unrelated descriptor reused by another thread.
    _ = linux.close(fd);
}

const t = std.testing;

const Fixture = struct {
    tmp: t.TmpDir,
    path: []u8,
    local: LinuxFs,
    root: contract.Root,

    fn init(gpa: std.mem.Allocator) !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        errdefer gpa.free(path);
        var local = LinuxFs.init(gpa);
        errdefer local.deinit();
        const root = try local.acquireRoot(path);
        return .{ .tmp = tmp, .path = path, .local = local, .root = root };
    }

    fn deinit(self: *Fixture) void {
        const gpa = self.local.gpa;
        self.local.deinit();
        gpa.free(self.path);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn opId(byte: u8) contract.OperationId {
    return [_]u8{byte} ** 16;
}

fn findEntry(listing: contract.Listing, name: []const u8) ?contract.DirEntry {
    for (listing.entries) |entry|
        if (std.mem.eql(u8, entry.name.bytes, name)) return entry;
    return null;
}

fn expectOutcome(tag: std.meta.Tag(contract.Outcome), outcome: contract.Outcome) !void {
    try t.expectEqual(tag, std.meta.activeTag(outcome));
}

fn externalWrite(local: *LinuxFs, root: contract.Root, name: []const u8, bytes: []const u8) !void {
    const state = try local.rootState(root);
    const name_z = try checkedNameZ(local.gpa, name);
    defer local.gpa.free(name_z);
    const fd = try fdResult(linux.openat(state.fd, name_z.ptr, .{
        .ACCMODE = .WRONLY,
        .TRUNC = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0));
    defer closeFd(fd);
    try writeAll(fd, bytes);
}

fn externalRename(local: *LinuxFs, root: contract.Root, old: []const u8, new: []const u8) !void {
    const state = try local.rootState(root);
    const old_z = try checkedNameZ(local.gpa, old);
    defer local.gpa.free(old_z);
    const new_z = try checkedNameZ(local.gpa, new);
    defer local.gpa.free(new_z);
    try renameNoReplace(state.fd, old_z.ptr, state.fd, new_z.ptr);
}

fn externalUnlink(local: *LinuxFs, root: contract.Root, name: []const u8) !void {
    const state = try local.rootState(root);
    const name_z = try checkedNameZ(local.gpa, name);
    defer local.gpa.free(name_z);
    try voidResult(linux.unlinkat(state.fd, name_z.ptr, 0));
}

fn externalCreateEmpty(local: *LinuxFs, root: contract.Root, name: []const u8) !void {
    const state = try local.rootState(root);
    const name_z = try checkedNameZ(local.gpa, name);
    defer local.gpa.free(name_z);
    const fd = try fdResult(linux.openat(state.fd, name_z.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0o600));
    closeFd(fd);
}

fn countOpenFds() !usize {
    const fd = try fdResult(linux.openat(linux.AT.FDCWD, "/proc/self/fd", .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0));
    defer closeFd(fd);
    var count: usize = 0;
    var buffer: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
    while (true) {
        const rc = linux.getdents64(fd, &buffer, buffer.len);
        const bytes_read = switch (linux.errno(rc)) {
            .SUCCESS => rc,
            .INTR => continue,
            else => return error.Io,
        };
        if (bytes_read == 0) return count;
        var offset: usize = 0;
        while (offset < bytes_read) {
            const dirent: *align(1) const linux.dirent64 = @ptrCast(&buffer[offset]);
            if (dirent.reclen == 0 or offset + dirent.reclen > bytes_read) return error.Io;
            const name_z: [*:0]const u8 = @ptrCast(&buffer[offset + @offsetOf(linux.dirent64, "name")]);
            const name = std.mem.span(name_z);
            offset += dirent.reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            count += 1;
        }
    }
}

test "linux provider rejects a directory leaf that fills the sentinel buffer" {
    const full = [_]u8{'a'} ** 4096;
    try t.expectError(error.InvalidName, openDirectoryAt(linux.AT.FDCWD, &full));
}

test "linux provider applies planned parents and preserves unusual raw names" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    const provider = fixture.local.provider();
    const unusual = "line\n-[]'\xff";
    const operations = [_]contract.Planned{
        .{
            .id = opId(1),
            .operation = .{ .create_directory = .{
                .destination = .{ .parent = .root, .name = try .init("tree") },
            } },
        },
        .{
            .id = opId(2),
            .operation = .{ .create_file = .{
                .destination = .{ .parent = .{ .planned = 0 }, .name = try .init(unusual) },
                .contents = "raw payload",
            } },
            .depends_on = &.{0},
        },
    };
    var report = try provider.apply(t.allocator, .{
        .root = fixture.root,
        .base_revision = &.{},
        .operations = &operations,
    });
    defer report.deinit();
    try expectOutcome(.applied, report.value.entries[0].outcome);
    try expectOutcome(.applied, report.value.entries[1].outcome);

    var root_listing = try provider.list(t.allocator, fixture.root, .root);
    defer root_listing.deinit();
    const tree = findEntry(root_listing.value, "tree") orelse return error.TestExpectedEqual;
    var tree_listing = try provider.list(t.allocator, fixture.root, tree.observation.node);
    defer tree_listing.deinit();
    const child = findEntry(tree_listing.value, unusual) orelse return error.TestExpectedEqual;
    var read = try provider.read(t.allocator, .{ .source = .{ .entry = .{
        .root = fixture.root,
        .ref = child.observation.node.entry,
        .revision = child.observation.revision,
    } } });
    defer read.deinit();
    try t.expectEqualStrings("raw payload", read.value.bytes);
}

test "linux provider recursively copies directories and symlinks without following them" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    const provider = fixture.local.provider();
    const setup = [_]contract.Planned{
        .{ .id = opId(10), .operation = .{ .create_directory = .{
            .destination = .{ .parent = .root, .name = try .init("source") },
            .mode = 0o750,
        } } },
        .{ .id = opId(11), .operation = .{ .create_file = .{
            .destination = .{ .parent = .{ .planned = 0 }, .name = try .init("file") },
            .contents = "inside",
            .mode = 0o640,
        } } },
        .{ .id = opId(12), .operation = .{ .create_directory = .{
            .destination = .{ .parent = .{ .planned = 0 }, .name = try .init("nested") },
        } } },
        .{ .id = opId(13), .operation = .{ .create_symlink = .{
            .destination = .{ .parent = .{ .planned = 2 }, .name = try .init("link") },
            .target = "../../outside",
        } } },
    };
    var setup_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &setup });
    defer setup_report.deinit();
    for (setup_report.value.entries) |entry| try expectOutcome(.applied, entry.outcome);

    var listing = try provider.list(t.allocator, fixture.root, .root);
    defer listing.deinit();
    const source = findEntry(listing.value, "source") orelse return error.TestExpectedEqual;
    const copy_operations = [_]contract.Planned{.{
        .id = opId(14),
        .operation = .{ .copy = .{
            .source = .{ .entry = .{
                .root = fixture.root,
                .ref = source.observation.node.entry,
                .revision = source.observation.revision,
            } },
            .destination = .{ .parent = .root, .name = try .init("copy") },
        } },
    }};
    var copy_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &copy_operations });
    defer copy_report.deinit();
    try expectOutcome(.applied, copy_report.value.entries[0].outcome);

    var after = try provider.list(t.allocator, fixture.root, .root);
    defer after.deinit();
    const copied = findEntry(after.value, "copy") orelse return error.TestExpectedEqual;
    try t.expectEqual(@as(?u32, 0o750), copied.observation.metadata.mode);
    var copied_listing = try provider.list(t.allocator, fixture.root, copied.observation.node);
    defer copied_listing.deinit();
    const copied_file = findEntry(copied_listing.value, "file") orelse return error.TestExpectedEqual;
    try t.expectEqual(@as(?u32, 0o640), copied_file.observation.metadata.mode);
    var read = try provider.read(t.allocator, .{ .source = .{ .entry = .{
        .root = fixture.root,
        .ref = copied_file.observation.node.entry,
        .revision = copied_file.observation.revision,
    } } });
    defer read.deinit();
    try t.expectEqualStrings("inside", read.value.bytes);
    const nested = findEntry(copied_listing.value, "nested") orelse return error.TestExpectedEqual;
    var nested_listing = try provider.list(t.allocator, fixture.root, nested.observation.node);
    defer nested_listing.deinit();
    const link = findEntry(nested_listing.value, "link") orelse return error.TestExpectedEqual;
    try t.expectEqual(contract.Kind.symlink, link.observation.kind);
    try t.expectEqualStrings("../../outside", link.observation.metadata.link_target.?);
}

test "linux provider never follows symlinks for chmod or permanent removal" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    const provider = fixture.local.provider();
    const setup = [_]contract.Planned{
        .{ .id = opId(20), .operation = .{ .create_file = .{
            .destination = .{ .parent = .root, .name = try .init("target") },
            .contents = "keep",
            .mode = 0o640,
        } } },
        .{ .id = opId(21), .operation = .{ .create_symlink = .{
            .destination = .{ .parent = .root, .name = try .init("link") },
            .target = "target",
        } } },
    };
    var setup_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &setup });
    defer setup_report.deinit();
    var listing = try provider.list(t.allocator, fixture.root, .root);
    defer listing.deinit();
    const target = findEntry(listing.value, "target") orelse return error.TestExpectedEqual;
    const link = findEntry(listing.value, "link") orelse return error.TestExpectedEqual;

    const chmod = [_]contract.Planned{.{
        .id = opId(22),
        .operation = .{ .set_permissions = .{
            .source = .{ .root = fixture.root, .ref = link.observation.node.entry, .revision = link.observation.revision },
            .mode = 0o777,
        } },
    }};
    var chmod_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &chmod });
    defer chmod_report.deinit();
    try expectOutcome(.unsupported, chmod_report.value.entries[0].outcome);

    var target_after_chmod = try provider.observe(t.allocator, fixture.root, target.observation.node);
    defer target_after_chmod.deinit();
    try t.expectEqual(@as(?u32, 0o640), target_after_chmod.value.metadata.mode);

    const removal = [_]contract.Planned{.{
        .id = opId(23),
        .operation = .{ .remove = .{
            .source = .{ .root = fixture.root, .ref = link.observation.node.entry, .revision = link.observation.revision },
            .policy = .permanent,
        } },
    }};
    var remove_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &removal });
    defer remove_report.deinit();
    try expectOutcome(.applied, remove_report.value.entries[0].outcome);
    var after = try provider.list(t.allocator, fixture.root, .root);
    defer after.deinit();
    try t.expect(findEntry(after.value, "link") == null);
    try t.expect(findEntry(after.value, "target") != null);
}

test "linux provider reports stale after external rename deletion and content change" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    const provider = fixture.local.provider();
    const setup = [_]contract.Planned{
        .{ .id = opId(30), .operation = .{ .create_file = .{ .destination = .{ .parent = .root, .name = try .init("renamed") }, .contents = "a" } } },
        .{ .id = opId(31), .operation = .{ .create_file = .{ .destination = .{ .parent = .root, .name = try .init("deleted") }, .contents = "b" } } },
        .{ .id = opId(32), .operation = .{ .create_file = .{ .destination = .{ .parent = .root, .name = try .init("changed") }, .contents = "c" } } },
    };
    var setup_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &setup });
    defer setup_report.deinit();
    var listing = try provider.list(t.allocator, fixture.root, .root);
    defer listing.deinit();
    const renamed = findEntry(listing.value, "renamed") orelse return error.TestExpectedEqual;
    const deleted = findEntry(listing.value, "deleted") orelse return error.TestExpectedEqual;
    const changed = findEntry(listing.value, "changed") orelse return error.TestExpectedEqual;

    try externalRename(&fixture.local, fixture.root, "renamed", "renamed-away");
    try externalUnlink(&fixture.local, fixture.root, "deleted");
    try externalWrite(&fixture.local, fixture.root, "changed", "content changed and size differs");
    const operations = [_]contract.Planned{
        .{ .id = opId(33), .operation = .{ .remove = .{
            .source = .{ .root = fixture.root, .ref = renamed.observation.node.entry, .revision = renamed.observation.revision },
            .policy = .permanent,
        } } },
        .{ .id = opId(34), .operation = .{ .set_permissions = .{
            .source = .{ .root = fixture.root, .ref = deleted.observation.node.entry, .revision = deleted.observation.revision },
            .mode = 0o600,
        } } },
        .{ .id = opId(35), .operation = .{ .rename = .{
            .source = .{ .root = fixture.root, .ref = changed.observation.node.entry, .revision = changed.observation.revision },
            .destination = .{ .parent = .root, .name = try .init("changed-away") },
        } } },
    };
    var report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &operations });
    defer report.deinit();
    for (report.value.entries) |entry| try expectOutcome(.stale, entry.outcome);

    var after = try provider.list(t.allocator, fixture.root, .root);
    defer after.deinit();
    try t.expect(findEntry(after.value, "changed") != null);
    try t.expect(findEntry(after.value, "changed-away") == null);
}

test "linux provider refuses destination collisions and hierarchy cycles" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    const provider = fixture.local.provider();
    const setup = [_]contract.Planned{
        .{ .id = opId(40), .operation = .{ .create_file = .{ .destination = .{ .parent = .root, .name = try .init("source") }, .contents = "source" } } },
        .{ .id = opId(41), .operation = .{ .create_file = .{ .destination = .{ .parent = .root, .name = try .init("taken") }, .contents = "original" } } },
        .{ .id = opId(42), .operation = .{ .create_directory = .{ .destination = .{ .parent = .root, .name = try .init("tree") } } } },
        .{ .id = opId(43), .operation = .{ .create_directory = .{ .destination = .{ .parent = .{ .planned = 2 }, .name = try .init("sub") } } } },
    };
    var setup_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &setup });
    defer setup_report.deinit();
    var root_listing = try provider.list(t.allocator, fixture.root, .root);
    defer root_listing.deinit();
    const source = findEntry(root_listing.value, "source") orelse return error.TestExpectedEqual;
    const taken = findEntry(root_listing.value, "taken") orelse return error.TestExpectedEqual;
    const tree = findEntry(root_listing.value, "tree") orelse return error.TestExpectedEqual;
    var tree_listing = try provider.list(t.allocator, fixture.root, tree.observation.node);
    defer tree_listing.deinit();
    const sub = findEntry(tree_listing.value, "sub") orelse return error.TestExpectedEqual;

    const operations = [_]contract.Planned{
        .{ .id = opId(44), .operation = .{ .copy = .{
            .source = .{ .entry = .{ .root = fixture.root, .ref = source.observation.node.entry, .revision = source.observation.revision } },
            .destination = .{ .parent = .root, .name = try .init("taken") },
        } } },
        .{ .id = opId(45), .operation = .{ .copy = .{
            .source = .{ .entry = .{ .root = fixture.root, .ref = tree.observation.node.entry, .revision = tree.observation.revision } },
            .destination = .{ .parent = .{ .entry = sub.observation.node.entry }, .name = try .init("again") },
        } } },
        .{ .id = opId(46), .operation = .{ .rename = .{
            .source = .{ .root = fixture.root, .ref = tree.observation.node.entry, .revision = tree.observation.revision },
            .destination = .{ .parent = .{ .entry = sub.observation.node.entry }, .name = try .init("moved") },
        } } },
    };
    var report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &operations });
    defer report.deinit();
    for (report.value.entries) |entry| try expectOutcome(.conflict, entry.outcome);

    var taken_read = try provider.read(t.allocator, .{ .source = .{ .entry = .{
        .root = fixture.root,
        .ref = taken.observation.node.entry,
        .revision = taken.observation.revision,
    } } });
    defer taken_read.deinit();
    try t.expectEqualStrings("original", taken_read.value.bytes);
}

test "linux provider rejects raw traversal and survives a directory-to-symlink swap" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    var outside = try Fixture.init(t.allocator);
    defer outside.deinit();
    const provider = fixture.local.provider();
    const setup = [_]contract.Planned{.{
        .id = opId(50),
        .operation = .{ .create_directory = .{ .destination = .{ .parent = .root, .name = try .init("safe") } } },
    }};
    var setup_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &setup });
    defer setup_report.deinit();
    var listing = try provider.list(t.allocator, fixture.root, .root);
    defer listing.deinit();
    const safe = findEntry(listing.value, "safe") orelse return error.TestExpectedEqual;

    const malicious = [_]contract.Planned{
        .{
            .id = opId(51),
            .operation = .{ .create_file = .{
                .destination = .{ .parent = .root, .name = .{ .bytes = "../escaped" } },
                .contents = "no",
            } },
        },
        .{
            .id = opId(53),
            .operation = .{ .create_file = .{
                .destination = .{ .parent = .root, .name = .{ .bytes = "/tmp/weft-absolute-escape" } },
                .contents = "no",
            } },
        },
    };
    var malicious_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &malicious });
    defer malicious_report.deinit();
    for (malicious_report.value.entries) |entry| try expectOutcome(.conflict, entry.outcome);

    try externalRename(&fixture.local, fixture.root, "safe", "safe-old");
    const root_fd = (try fixture.local.rootState(fixture.root)).fd;
    const target_z = try fixture.local.gpa.dupeZ(u8, outside.path);
    defer fixture.local.gpa.free(target_z);
    try voidResult(linux.symlinkat(target_z.ptr, root_fd, "safe"));
    const through_swapped = [_]contract.Planned{.{
        .id = opId(52),
        .operation = .{ .create_file = .{
            .destination = .{ .parent = .{ .entry = safe.observation.node.entry }, .name = try .init("escaped") },
            .contents = "no",
        } },
    }};
    var swap_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &through_swapped });
    defer swap_report.deinit();
    try expectOutcome(.stale, swap_report.value.entries[0].outcome);
    const outside_provider = outside.local.provider();
    var outside_listing = try outside_provider.list(t.allocator, outside.root, .root);
    defer outside_listing.deinit();
    try t.expect(findEntry(outside_listing.value, "escaped") == null);
}

test "linux provider keeps quarantine and watch capabilities honest" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    const provider = fixture.local.provider();
    const capabilities = try provider.capabilities(fixture.root);
    try t.expect(capabilities.exclusive_create);
    try t.expect(capabilities.symlink);
    try t.expect(capabilities.posix_mode);
    try t.expect(!capabilities.quarantine);
    try t.expectEqual(contract.GuardStrength.preflight, capabilities.guard_strength);
    try t.expectEqual(contract.WatchPrecision.none, capabilities.watch);
    try t.expectError(error.Unsupported, provider.watch(fixture.root, .root, true));

    const setup = [_]contract.Planned{.{
        .id = opId(60),
        .operation = .{ .create_file = .{ .destination = .{ .parent = .root, .name = try .init("kept") }, .contents = "keep" } },
    }};
    var setup_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &setup });
    defer setup_report.deinit();
    var listing = try provider.list(t.allocator, fixture.root, .root);
    defer listing.deinit();
    const kept = findEntry(listing.value, "kept") orelse return error.TestExpectedEqual;
    const removal = [_]contract.Planned{.{
        .id = opId(61),
        .operation = .{ .remove = .{
            .source = .{ .root = fixture.root, .ref = kept.observation.node.entry, .revision = kept.observation.revision },
        } },
    }};
    var report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &removal });
    defer report.deinit();
    try expectOutcome(.unsupported, report.value.entries[0].outcome);
    var after = try provider.list(t.allocator, fixture.root, .root);
    defer after.deinit();
    try t.expect(findEntry(after.value, "kept") != null);
}

test "linux provider applies chmod rename and recursive permanent removal" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    const provider = fixture.local.provider();
    const setup = [_]contract.Planned{
        .{ .id = opId(70), .operation = .{ .create_directory = .{
            .destination = .{ .parent = .root, .name = try .init("tree") },
        } } },
        .{ .id = opId(71), .operation = .{ .create_directory = .{
            .destination = .{ .parent = .{ .planned = 0 }, .name = try .init("nested") },
        } } },
        .{ .id = opId(72), .operation = .{ .create_file = .{
            .destination = .{ .parent = .{ .planned = 1 }, .name = try .init("before") },
            .contents = "payload",
            .mode = 0o644,
        } } },
    };
    var setup_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &setup });
    defer setup_report.deinit();
    var root_listing = try provider.list(t.allocator, fixture.root, .root);
    defer root_listing.deinit();
    const tree = findEntry(root_listing.value, "tree") orelse return error.TestExpectedEqual;
    var tree_listing = try provider.list(t.allocator, fixture.root, tree.observation.node);
    defer tree_listing.deinit();
    const nested = findEntry(tree_listing.value, "nested") orelse return error.TestExpectedEqual;
    var nested_listing = try provider.list(t.allocator, fixture.root, nested.observation.node);
    defer nested_listing.deinit();
    const before = findEntry(nested_listing.value, "before") orelse return error.TestExpectedEqual;

    const chmod_ops = [_]contract.Planned{.{
        .id = opId(73),
        .operation = .{ .set_permissions = .{
            .source = .{ .root = fixture.root, .ref = before.observation.node.entry, .revision = before.observation.revision },
            .mode = 0o600,
        } },
    }};
    var chmod_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &chmod_ops });
    defer chmod_report.deinit();
    try expectOutcome(.applied, chmod_report.value.entries[0].outcome);
    var after_chmod = try provider.observe(t.allocator, fixture.root, before.observation.node);
    defer after_chmod.deinit();
    try t.expectEqual(@as(?u32, 0o600), after_chmod.value.metadata.mode);

    const rename_ops = [_]contract.Planned{.{
        .id = opId(74),
        .operation = .{ .rename = .{
            .source = .{ .root = fixture.root, .ref = before.observation.node.entry, .revision = after_chmod.value.revision },
            .destination = .{ .parent = .{ .entry = nested.observation.node.entry }, .name = try .init("after") },
        } },
    }};
    var rename_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &rename_ops });
    defer rename_report.deinit();
    try expectOutcome(.applied, rename_report.value.entries[0].outcome);
    var after_rename = try provider.list(t.allocator, fixture.root, nested.observation.node);
    defer after_rename.deinit();
    try t.expect(findEntry(after_rename.value, "before") == null);
    try t.expect(findEntry(after_rename.value, "after") != null);

    var fresh_root = try provider.list(t.allocator, fixture.root, .root);
    defer fresh_root.deinit();
    const fresh_tree = findEntry(fresh_root.value, "tree") orelse return error.TestExpectedEqual;
    const removal = [_]contract.Planned{.{
        .id = opId(75),
        .operation = .{ .remove = .{
            .source = .{ .root = fixture.root, .ref = fresh_tree.observation.node.entry, .revision = fresh_tree.observation.revision },
            .policy = .permanent,
        } },
    }};
    var remove_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &removal });
    defer remove_report.deinit();
    try expectOutcome(.applied, remove_report.value.entries[0].outcome);
    var final = try provider.list(t.allocator, fixture.root, .root);
    defer final.deinit();
    try t.expect(findEntry(final.value, "tree") == null);
}

test "linux provider keeps roots explicit and copies regular files across acquired roots" {
    var first_tmp = t.tmpDir(.{});
    defer first_tmp.cleanup();
    var second_tmp = t.tmpDir(.{});
    defer second_tmp.cleanup();
    const first_path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{first_tmp.sub_path});
    defer t.allocator.free(first_path);
    const second_path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{second_tmp.sub_path});
    defer t.allocator.free(second_path);
    var local = LinuxFs.init(t.allocator);
    defer local.deinit();
    const first_root = try local.acquireRoot(first_path);
    const second_root = try local.acquireRoot(second_path);
    const provider = local.provider();

    const setup = [_]contract.Planned{.{
        .id = opId(80),
        .operation = .{ .create_file = .{
            .destination = .{ .parent = .root, .name = try .init("source") },
            .contents = "cross-root",
        } },
    }};
    var setup_report = try provider.apply(t.allocator, .{ .root = first_root, .base_revision = &.{}, .operations = &setup });
    defer setup_report.deinit();
    var first_listing = try provider.list(t.allocator, first_root, .root);
    defer first_listing.deinit();
    const source = findEntry(first_listing.value, "source") orelse return error.TestExpectedEqual;

    try t.expectError(error.Stale, provider.read(t.allocator, .{ .source = .{ .entry = .{
        .root = second_root,
        .ref = source.observation.node.entry,
        .revision = source.observation.revision,
    } } }));

    const copy_ops = [_]contract.Planned{.{
        .id = opId(81),
        .operation = .{ .copy = .{
            .source = .{ .entry = .{
                .root = first_root,
                .ref = source.observation.node.entry,
                .revision = source.observation.revision,
            } },
            .destination = .{ .parent = .root, .name = try .init("copied") },
        } },
    }};
    var copy_report = try provider.apply(t.allocator, .{ .root = second_root, .base_revision = &.{}, .operations = &copy_ops });
    defer copy_report.deinit();
    try expectOutcome(.applied, copy_report.value.entries[0].outcome);
    var second_listing = try provider.list(t.allocator, second_root, .root);
    defer second_listing.deinit();
    const copied = findEntry(second_listing.value, "copied") orelse return error.TestExpectedEqual;
    var read = try provider.read(t.allocator, .{ .source = .{ .entry = .{
        .root = second_root,
        .ref = copied.observation.node.entry,
        .revision = copied.observation.revision,
    } } });
    defer read.deinit();
    try t.expectEqualStrings("cross-root", read.value.bytes);
}

test "linux provider lists thousands of entries without retaining per-entry fds" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    const entry_count = 4096;
    var name_buffer: [64]u8 = undefined;
    for (0..entry_count) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "bulk-{d}", .{index});
        try externalCreateEmpty(&fixture.local, fixture.root, name);
    }

    const fds_before = try countOpenFds();
    const provider = fixture.local.provider();
    var listing = try provider.list(t.allocator, fixture.root, .root);
    defer listing.deinit();
    const fds_after = try countOpenFds();
    try t.expectEqual(@as(usize, entry_count), listing.value.entries.len);
    try t.expectEqual(@as(usize, entry_count), fixture.local.entries.items.len);
    try t.expectEqual(fds_before, fds_after);
}

test "linux provider transactionally reconciles churn into bounded reusable slots" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    const provider = fixture.local.provider();
    const entry_count = 192;
    var name_buffer: [64]u8 = undefined;
    for (0..entry_count) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "a-{d}", .{index});
        try externalCreateEmpty(&fixture.local, fixture.root, name);
    }

    var initial = try provider.list(t.allocator, fixture.root, .root);
    defer initial.deinit();
    const first = findEntry(initial.value, "a-0") orelse return error.TestExpectedEqual;
    const stale_ref = first.observation.node.entry;
    const slot_bound = fixture.local.entries.items.len;
    const capacity_bound = fixture.local.entries.capacity;
    try t.expectEqual(@as(usize, entry_count), slot_bound);

    var current_prefix: u8 = 'a';
    for (0..24) |round| {
        const next_prefix: u8 = if (current_prefix == 'a') 'b' else 'a';
        for (0..entry_count) |index| {
            const old_name = try std.fmt.bufPrint(&name_buffer, "{c}-{d}", .{ current_prefix, index });
            try externalUnlink(&fixture.local, fixture.root, old_name);
            const new_name = try std.fmt.bufPrint(&name_buffer, "{c}-{d}", .{ next_prefix, index });
            try externalCreateEmpty(&fixture.local, fixture.root, new_name);
        }
        current_prefix = next_prefix;

        var relisted = try provider.list(t.allocator, fixture.root, .root);
        defer relisted.deinit();
        try t.expectEqual(@as(usize, entry_count), relisted.value.entries.len);
        try t.expectEqual(slot_bound, fixture.local.entries.items.len);
        try t.expectEqual(capacity_bound, fixture.local.entries.capacity);
        for (relisted.value.entries) |entry| try t.expect(entry.observation.node.entry.slot < slot_bound);
        if (round == 0)
            try t.expectError(error.Stale, provider.observe(t.allocator, fixture.root, .{ .entry = stale_ref }));
    }
}

test "linux provider generation-invalidates a same-name replacement on relist" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    const provider = fixture.local.provider();
    try externalCreateEmpty(&fixture.local, fixture.root, "same");
    var before = try provider.list(t.allocator, fixture.root, .root);
    defer before.deinit();
    const old = findEntry(before.value, "same") orelse return error.TestExpectedEqual;
    const old_ref = old.observation.node.entry;

    try externalUnlink(&fixture.local, fixture.root, "same");
    const state = try fixture.local.rootState(fixture.root);
    const fd = try fdResult(linux.openat(state.fd, "same", .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0o600));
    try writeAll(fd, "replacement");
    closeFd(fd);

    var after = try provider.list(t.allocator, fixture.root, .root);
    defer after.deinit();
    const replacement = findEntry(after.value, "same") orelse return error.TestExpectedEqual;
    const new_ref = replacement.observation.node.entry;
    try t.expectEqual(old_ref.slot, new_ref.slot);
    try t.expect(old_ref.generation != new_ref.generation);
    try t.expectError(error.Stale, provider.observe(t.allocator, fixture.root, .{ .entry = old_ref }));
}

test "linux identity requires birth time for exact entry reuse" {
    const weak: LinuxFs.Identity = .{
        .dev_major = 8,
        .dev_minor = 1,
        .mount_id = 7,
        .inode = 42,
        .has_birth_time = false,
        .birth_sec = 0,
        .birth_nsec = 0,
    };
    try t.expect(weak.locationEql(weak));
    try t.expect(!weak.eql(weak));

    var strong: LinuxFs.Identity = weak;
    strong.has_birth_time = true;
    strong.birth_sec = 123;
    strong.birth_nsec = 456;
    try t.expect(strong.eql(strong));
    try t.expect(!strong.eql(weak));
}

test "linux reconciliation leaves registry untouched when publication growth fails" {
    var failing_state = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    const gpa = failing_state.allocator();
    var provider = LinuxFs.init(gpa);
    defer provider.deinit();

    const root: contract.Root = .{ .authority = .here, .slot = 0, .generation = 1 };
    const unrelated_parent: contract.NodeRef = .{ .entry = .{
        .authority = .here,
        .slot = 99,
        .generation = 1,
    } };
    const identity: LinuxFs.Identity = .{
        .dev_major = 8,
        .dev_minor = 1,
        .mount_id = 7,
        .inode = 42,
        .has_birth_time = true,
        .birth_sec = 123,
        .birth_nsec = 456,
    };
    const snapshot: LinuxFs.Snapshot = .{
        .identity = identity,
        .kind = .regular,
        .mode = 0o600,
        .size = 0,
        .nlink = 1,
        .modified_sec = 0,
        .modified_nsec = 0,
        .changed_sec = 0,
        .changed_nsec = 0,
    };

    try provider.entries.ensureTotalCapacityPrecise(gpa, 1);
    const original_name = try gpa.dupe(u8, "unrelated");
    provider.entries.appendAssumeCapacity(.{
        .generation = 1,
        .value = .{
            .root = root,
            .parent = unrelated_parent,
            .name = original_name,
            .identity = identity,
            .revision = revisionBytes(&snapshot),
        },
    });
    const old_generation = provider.entries.items[0].generation;
    const old_capacity = provider.entries.capacity;
    const allocations_before = failing_state.alloc_index;
    // The staged name allocation succeeds; the following registry growth
    // allocation fails. This is the fallible publication boundary.
    failing_state.fail_index = allocations_before + 1;

    const pending = [_]LinuxFs.PendingEntry{.{
        .name = "new",
        .snapshot = snapshot,
        .link_target = null,
    }};
    var scratch_arena = std.heap.ArenaAllocator.init(t.allocator);
    defer scratch_arena.deinit();
    try t.expectError(error.OutOfMemory, provider.reconcileDirectory(scratch_arena.allocator(), root, .root, &pending));
    try t.expectEqual(@as(usize, 1), provider.entries.items.len);
    try t.expectEqual(old_capacity, provider.entries.capacity);
    try t.expectEqual(old_generation, provider.entries.items[0].generation);
    try t.expectEqualStrings("unrelated", provider.entries.items[0].value.?.name);
}

test "linux listing allocation failures never publish partial reconciliation" {
    const entry_count = 96;
    var name_buffer: [32]u8 = undefined;
    var counted_fixture = try Fixture.init(t.allocator);
    defer counted_fixture.deinit();
    for (0..entry_count) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "old-{d}", .{index});
        try externalCreateEmpty(&counted_fixture.local, counted_fixture.root, name);
    }
    var counted_initial = try counted_fixture.local.provider().list(t.allocator, counted_fixture.root, .root);
    defer counted_initial.deinit();

    // Determine every allocator boundary in a representative listing. Each
    // failure point is replayed against a fresh provider below; failures must
    // leave the pre-reconciliation slot, generation, and name intact.
    var counting_state = t.FailingAllocator.init(t.allocator, .{});
    var counted_listing = try counted_fixture.local.provider().list(
        counting_state.allocator(),
        counted_fixture.root,
        .root,
    );
    counted_listing.deinit();
    try t.expect(counting_state.alloc_index > 0);

    for (0..counting_state.alloc_index) |fail_index| {
        var fixture = try Fixture.init(t.allocator);
        defer fixture.deinit();
        for (0..entry_count) |index| {
            const name = try std.fmt.bufPrint(&name_buffer, "old-{d}", .{index});
            try externalCreateEmpty(&fixture.local, fixture.root, name);
        }
        var before = try fixture.local.provider().list(t.allocator, fixture.root, .root);
        defer before.deinit();
        const old = findEntry(before.value, "old-0") orelse return error.TestExpectedEqual;
        const old_ref = old.observation.node.entry;
        try externalRename(&fixture.local, fixture.root, "old-0", "new-0");

        var failing_state = t.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
        const result = fixture.local.provider().list(failing_state.allocator(), fixture.root, .root);
        if (result) |listing| {
            var owned = listing;
            owned.deinit();
        } else |err| switch (err) {
            error.OutOfMemory => {
                const slot = &fixture.local.entries.items[old_ref.slot];
                try t.expectEqual(old_ref.generation, slot.generation);
                const state = slot.value orelse return error.TestExpectedEqual;
                try t.expectEqualStrings("old-0", state.name);
            },
            else => return err,
        }
    }
}

test "linux readlink releases its buffer when shrinking realloc fails" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    const provider = fixture.local.provider();
    const setup = [_]contract.Planned{.{
        .id = opId(91),
        .operation = .{ .create_symlink = .{
            .destination = .{ .parent = .root, .name = try .init("link") },
            .target = "target",
        } },
    }};
    var report = try provider.apply(t.allocator, .{
        .root = fixture.root,
        .base_revision = &.{},
        .operations = &setup,
    });
    defer report.deinit();
    try expectOutcome(.applied, report.value.entries[0].outcome);

    var failing_state = t.FailingAllocator.init(t.allocator, .{
        .fail_index = 2,
        .resize_fail_index = 0,
    });
    try t.expectError(error.OutOfMemory, readlinkAt(
        failing_state.allocator(),
        (try fixture.local.rootState(fixture.root)).fd,
        "link",
    ));
    try t.expectEqual(failing_state.allocations, failing_state.deallocations);
}

test "linux file leases survive namespace deletion and replacement" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    const provider = fixture.local.provider();
    const setup = [_]contract.Planned{.{
        .id = opId(92),
        .operation = .{ .create_file = .{ .destination = .{ .parent = .root, .name = try .init("source") }, .contents = "payload" } },
    }};
    var setup_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &setup });
    defer setup_report.deinit();
    var listing = try provider.list(t.allocator, fixture.root, .root);
    defer listing.deinit();
    const source = findEntry(listing.value, "source") orelse return error.TestExpectedEqual;
    const lease_ref = try provider.capture(.{ .root = fixture.root, .ref = source.observation.node.entry, .revision = source.observation.revision });
    const lease: contract.LeaseSource = .{ .root = fixture.root, .ref = lease_ref };
    try externalUnlink(&fixture.local, fixture.root, "source");

    const operation = [_]contract.Planned{.{
        .id = opId(93),
        .operation = .{ .copy = .{ .source = .{ .lease = lease }, .destination = .{ .parent = .root, .name = try .init("restored") } } },
    }};
    var report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &operation });
    defer report.deinit();
    try expectOutcome(.applied, report.value.entries[0].outcome);
    provider.releaseLease(lease);
    var stale = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &operation });
    defer stale.deinit();
    try expectOutcome(.stale, stale.value.entries[0].outcome);
}

test "linux symlink leases preserve link text without following" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    const provider = fixture.local.provider();
    const setup = [_]contract.Planned{.{
        .id = opId(94),
        .operation = .{ .create_symlink = .{ .destination = .{ .parent = .root, .name = try .init("link") }, .target = "outside/target" } },
    }};
    var setup_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &setup });
    defer setup_report.deinit();
    var listing = try provider.list(t.allocator, fixture.root, .root);
    defer listing.deinit();
    const source = findEntry(listing.value, "link") orelse return error.TestExpectedEqual;
    const lease_ref = try provider.capture(.{ .root = fixture.root, .ref = source.observation.node.entry, .revision = source.observation.revision });
    const lease: contract.LeaseSource = .{ .root = fixture.root, .ref = lease_ref };
    try externalUnlink(&fixture.local, fixture.root, "link");
    const operation = [_]contract.Planned{.{
        .id = opId(95),
        .operation = .{ .copy = .{ .source = .{ .lease = lease }, .destination = .{ .parent = .root, .name = try .init("link-copy") } } },
    }};
    var report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &operation });
    defer report.deinit();
    try expectOutcome(.applied, report.value.entries[0].outcome);
    var after = try provider.list(t.allocator, fixture.root, .root);
    defer after.deinit();
    const copy = findEntry(after.value, "link-copy") orelse return error.TestExpectedEqual;
    try t.expectEqual(contract.Kind.symlink, copy.observation.kind);
    try t.expectEqualStrings("outside/target", copy.observation.metadata.link_target.?);
}

test "linux bounded lease read rejects bytes beyond its limit" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    const provider = fixture.local.provider();
    const setup = [_]contract.Planned{.{
        .id = opId(97),
        .operation = .{ .create_file = .{ .destination = .{ .parent = .root, .name = try .init("oversize") }, .contents = "12" } },
    }};
    var setup_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &setup });
    defer setup_report.deinit();
    var listing = try provider.list(t.allocator, fixture.root, .root);
    defer listing.deinit();
    const source = findEntry(listing.value, "oversize") orelse return error.TestExpectedEqual;
    const resolved = try fixture.local.resolveEntry(fixture.root, source.observation.node.entry);
    defer resolved.close();
    try t.expectError(error.LimitExceeded, readWholeFile(
        t.allocator,
        resolved.parent_fd,
        resolved.state.name,
        resolved.snapshot,
        1,
    ));
}

test "linux directory leases are explicit unsupported" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.deinit();
    const provider = fixture.local.provider();
    const setup = [_]contract.Planned{.{
        .id = opId(96),
        .operation = .{ .create_directory = .{ .destination = .{ .parent = .root, .name = try .init("tree") } } },
    }};
    var setup_report = try provider.apply(t.allocator, .{ .root = fixture.root, .base_revision = &.{}, .operations = &setup });
    defer setup_report.deinit();
    var listing = try provider.list(t.allocator, fixture.root, .root);
    defer listing.deinit();
    const tree = findEntry(listing.value, "tree") orelse return error.TestExpectedEqual;
    try t.expectError(error.Unsupported, provider.capture(.{ .root = fixture.root, .ref = tree.observation.node.entry, .revision = tree.observation.revision }));
}

test "linux provider closes root fds and generation-checks reused root slots" {
    var fixture = try Fixture.init(t.allocator);
    defer fixture.tmp.cleanup();
    defer t.allocator.free(fixture.path);
    const first = fixture.root;
    const first_fd = (try fixture.local.rootState(first)).fd;
    const provider = fixture.local.provider();
    const setup = [_]contract.Planned{.{
        .id = opId(90),
        .operation = .{ .create_file = .{
            .destination = .{ .parent = .root, .name = try .init("pinned") },
            .contents = "identity",
        } },
    }};
    var setup_report = try provider.apply(t.allocator, .{ .root = first, .base_revision = &.{}, .operations = &setup });
    defer setup_report.deinit();
    var listing = try provider.list(t.allocator, first, .root);
    defer listing.deinit();
    _ = findEntry(listing.value, "pinned") orelse return error.TestExpectedEqual;
    fixture.local.releaseRoot(first);
    try t.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(first_fd, linux.F.GETFD, 0)));
    try t.expectError(error.Stale, fixture.local.observe(t.allocator, first, .root));

    const second = try fixture.local.acquireRoot(fixture.path);
    try t.expectEqual(first.slot, second.slot);
    try t.expect(first.generation != second.generation);
    const second_fd = (try fixture.local.rootState(second)).fd;
    fixture.local.deinit();
    try t.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(second_fd, linux.F.GETFD, 0)));
}

test {
    std.testing.refAllDecls(@This());
}
