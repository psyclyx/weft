//! Filesystem host operations. Every function here may block — none is
//! ever called on the hot path: reads happen at startup/open, writes run
//! on task-pool workers as fallible requests. Each call brings its own
//! `std.Io.Threaded` instance (0.16's blocking Io implementation); at a
//! few saves per minute that costs nothing and keeps the editor free of
//! a global Io singleton.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stemma = @import("stemma");

pub const ReadError = std.Io.Dir.ReadFileAllocError;
pub const WriteError = std.Io.Dir.WriteFileError || std.Io.Dir.RenameError || Allocator.Error;

/// What a cwd-relative path is, without reading it: absent, a regular file,
/// a directory, or something else (symlink target kind, socket, …). The
/// building block for existence checks and project-root detection (does
/// `<dir>/.git` exist, and is it a file or a dir — worktrees make it either).
pub const Kind = enum(i32) { none = 0, file = 1, dir = 2, other = 3 };

/// The editor process's own working directory, into `buf`. Null when the OS
/// refuses to name it (a deleted cwd).
///
/// ONE implementation, because there are exactly two honest callers and they
/// must agree: `place.Realized.process` — the degenerate place — is defined as
/// this directory, and a relative path is only meaningful when joined onto it.
/// Anything else asking "where am I" is the ambient-cwd bug `doc/place.md`
/// exists to remove; ask for a place instead.
pub fn processDirectory(buf: []u8) ?[]const u8 {
    const rc = std.os.linux.getcwd(buf.ptr, buf.len);
    if (@as(isize, @bitCast(rc)) < 0) return null;
    return std.mem.sliceTo(buf[0..rc], 0);
}

/// What a path is, beyond its `Kind` — the facts a lister or an annotator
/// wants and `statKind` cannot give. RAW, deliberately: `mode` is the
/// permission bits as the kernel reports them (the type lives in `kind`,
/// never in both places), `mtime_ns` is nanoseconds since the epoch. Nothing
/// here is interpreted — what "executable", "large" or "recently" mean is the
/// asker's question, and this file has no business having an opinion about it.
///
/// Absence is DATA, not an error (`absent` below), for the same reason
/// `statKind` answers `.none` rather than failing: a caller enumerating a
/// directory must be able to tell "gone" from "refused", and only refusal is
/// exceptional.
pub const Stat = struct {
    kind: Kind = .none,
    /// Permission bits only (`& 0o7777`). Both `statFull` and
    /// `rooted_fs.RootedFs.stat` mask identically, so the confined and
    /// unconfined answers cannot disagree about what this field means.
    mode: u32 = 0,
    size: u64 = 0,
    mtime_ns: i64 = 0,
    nlink: u32 = 0,

    pub const absent: Stat = .{};
};

/// The permission-bit mask both stat paths apply. Named once so the two
/// cannot drift.
pub const mode_mask: u32 = 0o7777;

pub fn statKind(gpa: Allocator, path: []const u8) Kind {
    return statFull(gpa, path).kind;
}

/// `statKind`, with the rest of the metadata. Mundane failure (absent,
/// unreadable) is `Stat.absent` — see that type's doc.
pub fn statFull(gpa: Allocator, path: []const u8) Stat {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const st = std.Io.Dir.cwd().statFile(threaded.io(), path, .{}) catch return .absent;
    return .{
        .kind = switch (st.kind) {
            .file => .file,
            .directory => .dir,
            else => .other,
        },
        .mode = @as(u32, @truncate(@as(u64, @bitCast(@as(i64, st.permissions.toMode()))))) & mode_mask,
        .size = st.size,
        // `Io.Timestamp` is an i96; an mtime that doesn't fit an i64 is a
        // clock nobody has, and saturating is a better answer than a trap.
        .mtime_ns = std.math.cast(i64, st.mtime.nanoseconds) orelse std.math.maxInt(i64),
        .nlink = std.math.cast(u32, st.nlink) orelse std.math.maxInt(u32),
    };
}

/// Read a whole file. Caller owns the bytes.
pub fn readAlloc(gpa: Allocator, path: []const u8) (ReadError || Allocator.Error)![]u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}

/// Atomic save: write to a sibling temp file, then rename over the
/// target. Takes ownership of `path` (gpa-owned) and of the rope
/// snapshot — the shape a task-pool spawn needs (the caller's editor
/// state can move on while this runs).
/// Delete a cwd-relative file (ignores "not found"). For tests + cleanup.
pub fn deleteFile(gpa: Allocator, path: []const u8) void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().deleteFile(threaded.io(), path) catch {};
}

/// Write `bytes` to `path` (cwd-relative), replacing it. The plain-bytes
/// counterpart to `writeRopeAtomic`, for plugin `fs.write`.
pub fn writeBytes(gpa: Allocator, path: []const u8, bytes: []const u8) WriteError!void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = bytes });
}

/// Write `bytes` to `path`, creating `dir` (and any missing parents) first.
/// `dir` should be `path`'s directory. Used for the compiled-module cache,
/// where the cache directory may not exist yet. Absolute paths are fine.
/// Atomic, through a pid-tagged sibling temp file: concurrent writers of the
/// same path each land their own temp, and a reader only ever sees a whole
/// file (what lets several test binaries share one `.cwasm` cache).
pub fn writeBytesMakingDirs(gpa: Allocator, dir: []const u8, path: []const u8, bytes: []const u8) WriteError!void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch {};
    const tmp = try std.fmt.allocPrint(gpa, "{s}.{d}.weft-tmp", .{ path, std.os.linux.getpid() });
    defer gpa.free(tmp);
    errdefer cwd.deleteFile(io, tmp) catch {};
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = bytes });
    try std.Io.Dir.rename(cwd, tmp, cwd, path, io);
}

/// Append `bytes` to `path` (created if absent) via read-concat-write — small
/// files only, which is the notes/capture use. For plugin `fs.append`.
pub fn appendBytes(gpa: Allocator, path: []const u8, bytes: []const u8) (ReadError || WriteError)!void {
    const existing: ?[]u8 = readAlloc(gpa, path) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    defer if (existing) |x| gpa.free(x);
    const prefix = existing orelse "";
    const combined = try gpa.alloc(u8, prefix.len + bytes.len);
    defer gpa.free(combined);
    @memcpy(combined[0..prefix.len], prefix);
    @memcpy(combined[prefix.len..], bytes);
    try writeBytes(gpa, path, combined);
}

pub fn writeRopeAtomic(gpa: Allocator, path: []u8, rope: stemma.Rope) WriteError!void {
    defer gpa.free(path);
    var snapshot = rope;
    defer snapshot.deinit(gpa);

    const bytes = try snapshot.toOwnedSlice(gpa);
    defer gpa.free(bytes);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.weft-tmp", .{path});
    defer gpa.free(tmp);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = bytes });
    try std.Io.Dir.rename(cwd, tmp, cwd, path, io);
}

pub const GuardedWriteError = WriteError || ReadError || error{Stale};

/// Guarded atomic save (design rev 4): write beside the target, then
/// rename only if the target still hashes to `expected` (null = the
/// file must not exist). Returns the new content token. `error.Stale`
/// means an external writer got there first — merge, retry.
pub fn writeRopeGuarded(
    gpa: Allocator,
    path: []u8,
    rope: stemma.Rope,
    expected: ?[]u8,
) GuardedWriteError![]u8 {
    defer gpa.free(path);
    defer if (expected) |e| gpa.free(e);
    var snapshot = rope;
    defer snapshot.deinit(gpa);
    const bytes = try snapshot.toOwnedSlice(gpa);
    defer gpa.free(bytes);

    // Test: the disk still matches the state the caller merged with.
    // (Check-then-rename — vim's own race window; see doc/substrate.md §2.)
    if (expected) |token| {
        const disk = readAlloc(gpa, path) catch |e| switch (e) {
            error.FileNotFound => return error.Stale, // deleted under us
            else => |err| return err,
        };
        defer gpa.free(disk);
        const have = backing_mod.localToken(disk);
        if (!std.mem.eql(u8, &have, token)) return error.Stale;
    } else {
        if (readAlloc(gpa, path)) |disk| {
            gpa.free(disk);
            return error.Stale; // exists but caller expected creation
        } else |_| {}
    }

    const tmp = try std.fmt.allocPrint(gpa, "{s}.weft-tmp", .{path});
    defer gpa.free(tmp);
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = bytes });
    try std.Io.Dir.rename(cwd, tmp, cwd, path, io);
    const token = backing_mod.localToken(bytes);
    return gpa.dupe(u8, &token);
}

/// Backing poll worker: null when the disk still matches `expected`,
/// else the new content + token (both gpa-owned, token first-freed by
/// the caller).
pub const Fetched = struct { bytes: []u8, token: []u8 };

pub fn pollFile(gpa: Allocator, path: []u8, expected: []u8) (ReadError || Allocator.Error)!?Fetched {
    defer gpa.free(path);
    defer gpa.free(expected);
    const disk = try readAlloc(gpa, path);
    errdefer gpa.free(disk);
    const token = backing_mod.localToken(disk);
    if (std.mem.eql(u8, &token, expected)) {
        gpa.free(disk);
        return null;
    }
    return .{ .bytes = disk, .token = try gpa.dupe(u8, &token) };
}

const backing_mod = @import("backing.zig");

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "read/write round trip through the atomic path" {
    const gpa = t.allocator;
    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();
    // Work with absolute-ish subpaths under the tmp dir via realpath
    // conventions: simplest is to write via our API into the tmp dir's
    // path composed manually.
    const dir_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/roundtrip.txt", .{tmp_dir.sub_path});
    defer gpa.free(dir_path);

    var rope = try stemma.Rope.fromSlice(gpa, "saved by a worker, honestly");
    defer rope.deinit(gpa);
    try writeRopeAtomic(gpa, try gpa.dupe(u8, dir_path), rope.snapshot());

    const back = try readAlloc(gpa, dir_path);
    defer gpa.free(back);
    try t.expectEqualStrings("saved by a worker, honestly", back);

    // statKind sees the file we just wrote, its parent dir, and reports absent
    // for a path that isn't there — the project-root probe's building block.
    try t.expectEqual(Kind.file, statKind(gpa, dir_path));
    const parent = std.fs.path.dirname(dir_path).?;
    try t.expectEqual(Kind.dir, statKind(gpa, parent));
    try t.expectEqual(Kind.none, statKind(gpa, ".zig-cache/tmp/definitely-not-here-xyzzy"));
}
