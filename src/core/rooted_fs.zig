//! rooted_fs — a filesystem confined to a root directory. Every path is
//! resolved relative to a held root dir-fd ONE COMPONENT AT A TIME, each step
//! an `openat(dir_fd, component, O_NOFOLLOW | ...)` relative to a descriptor
//! this module already holds — the classic TOCTOU-free walk. There is no
//! string path ever handed to the kernel whole, no realpath, and no window
//! between a check and the open: a rename or symlink swap racing the walk can
//! only make a step FAIL, never redirect it outside the root. This is the
//! confinement the `.peer` fs server (design Part D) needs so a connected
//! client can never read outside the host's shared root.
//!
//! The policy (the same one `openat2(RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS)`
//! enforced before this walk replaced it, so it is portable libc — Linux and
//! macOS — rather than a Linux syscall):
//! - an absolute path is `error.Confined`;
//! - `..` pops back to a directory fd the walk already holds; a `..` that
//!   would climb above the root is `error.Confined` (so `sub/../file` that
//!   stays inside is fine, `../x` is not);
//! - ANY symlink, anywhere in the chain (intermediate or final), is
//!   `error.Confined` — `O_NOFOLLOW` refuses it (`ELOOP`; some kernels say
//!   `ENOTDIR` for a symlink opened `O_DIRECTORY`, so that case is
//!   disambiguated with a `readlinkat` probe);
//! - `EACCES`/`EPERM` is `error.Confined` (refused, not absent);
//! - a missing component is `error.NotFound`;
//! - empty components (`a//b`) and `.` are skipped; a trailing `/` requires
//!   the final component to be a directory; `""` is `error.NotFound`.

const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;

pub const Error = error{ OpenRoot, Confined, NotFound, Io, Stale } || Allocator.Error;

/// What a confined path IS, for `kind` below. Deliberately has no "absent"
/// variant: absence is `error.NotFound`, the same signal `read` already
/// gives, so a caller can never confuse "nothing there" with "refused".
pub const Kind = enum { file, dir, other };

/// The permission-bit mask `stat` applies. Mirrors `file.mode_mask` (this
/// module imports nothing from `file.zig` — see `stat`'s doc).
pub const mode_mask: u32 = 0o7777;

/// A confined path's metadata — `Kind` plus what a lister wants. Mirrors
/// `file.Stat` minus its `.none` kind, for the same reason `Kind` does.
pub const Stat = struct {
    kind: Kind,
    mode: u32,
    size: u64,
    mtime_ns: i64,
    nlink: u32,
};

/// The deepest directory chain one walk holds open at once (each held fd is
/// a level `..` can pop back to). Deeper paths are `error.Io`, not a silent
/// truncation of the walk.
const max_depth = 64;

/// The longest single path component the walk will name (macOS and Linux
/// `NAME_MAX` are both 255).
const max_component = 255;

pub const RootedFs = struct {
    root_fd: i32,

    /// Open `root` (cwd-relative or absolute) as the confinement root.
    pub fn open(root: [*:0]const u8) Error!RootedFs {
        const rc = c.openat(c.AT.FDCWD, root, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, @as(c_uint, 0));
        if (c.errno(rc) != .SUCCESS) return error.OpenRoot;
        return .{ .root_fd = rc };
    }

    pub fn close(self: *RootedFs) void {
        if (self.root_fd >= 0) _ = c.close(self.root_fd);
        self.root_fd = -1;
    }

    /// Open a NUL-terminated path relative to the root, confined beneath it
    /// (the module doc's policy). `o_flags` gains `NOFOLLOW` (and `DIRECTORY`
    /// for a trailing `/`); the caller owns the returned fd.
    fn openBeneath(self: *const RootedFs, rel: [*:0]const u8, o_flags: c.O, mode: u32) Error!i32 {
        var walk = try self.walkToParent(std.mem.span(rel));
        defer walk.close();
        var flags = o_flags;
        flags.NOFOLLOW = true;
        if (walk.dir_only) flags.DIRECTORY = true;
        return openComponent(walk.parent(), walk.leaf orelse ".", flags, mode);
    }

    /// Resolve every component of `rel` but the last, holding each directory
    /// as an fd. Returns the held chain and the final component (`null` when
    /// `rel` names the directory the walk ended in, e.g. `.` or `sub/..`).
    fn walkToParent(self: *const RootedFs, rel: []const u8) Error!Walk {
        if (rel.len == 0) return error.NotFound;
        if (rel[0] == '/') return error.Confined;
        var walk: Walk = .{ .root_fd = self.root_fd, .dir_only = rel[rel.len - 1] == '/' };
        errdefer walk.close();
        var pending: ?[]const u8 = null;
        var it = std.mem.tokenizeScalar(u8, rel, '/');
        while (it.next()) |component| {
            if (std.mem.eql(u8, component, ".")) continue;
            if (std.mem.eql(u8, component, "..")) {
                if (pending != null) {
                    // `x/..`: `x` must still resolve, as a real directory,
                    // exactly as the kernel would require — then it is popped.
                    try walk.descend(pending.?);
                    pending = null;
                }
                try walk.ascend();
                continue;
            }
            if (pending) |dir_name| try walk.descend(dir_name);
            pending = component;
        }
        walk.leaf = pending;
        return walk;
    }

    /// Read the whole file at `rel` (confined) into an owned slice.
    pub fn read(self: *const RootedFs, gpa: Allocator, rel: [*:0]const u8) Error![]u8 {
        const fd = try self.openBeneath(rel, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        defer _ = c.close(fd);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const rc = c.read(fd, &buf, buf.len);
            const n: usize = switch (c.errno(rc)) {
                .SUCCESS => @intCast(rc),
                .INTR => continue,
                else => return error.Io,
            };
            if (n == 0) break;
            try out.appendSlice(gpa, buf[0..n]);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Write `bytes` to `rel` (confined), replacing it. Creates parent-less
    /// files only (the root itself); truncates an existing file.
    pub fn write(self: *const RootedFs, rel: [*:0]const u8, bytes: []const u8) Error!void {
        const fd = try self.openBeneath(
            rel,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
            0o644,
        );
        defer _ = c.close(fd);
        try writeAll(fd, bytes);
    }

    /// Append `bytes` to `rel` (confined, created if absent) — the append
    /// counterpart to `write`, above (O_APPEND instead of O_TRUNC). Used by
    /// `wasm_host/fs.zig`'s `fsAppend` when a `.fs_root` grant limits the
    /// call (doc/contextual-workspace-architecture.md §13.5).
    pub fn append(self: *const RootedFs, rel: [*:0]const u8, bytes: []const u8) Error!void {
        const fd = try self.openBeneath(
            rel,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true },
            0o644,
        );
        defer _ = c.close(fd);
        try writeAll(fd, bytes);
    }

    /// List the directory at `rel` (confined), returning names newline-joined
    /// (owned). Directories keep a trailing `/`, so a consumer (files) can tell
    /// them apart. Order is filesystem order.
    pub fn list(self: *const RootedFs, gpa: Allocator, rel: [*:0]const u8) Error![]u8 {
        const fd = try self.openBeneath(rel, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        defer _ = c.close(fd);
        // std's iterator reads the confined fd itself (getdents64 /
        // getdirentries64) through a blocking, allocation-free `Io`.
        var threaded: std.Io.Threaded = .init_single_threaded;
        const dir: std.Io.Dir = .{ .handle = fd };
        var it = dir.iterateAssumeFirstIteration();
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        while (it.next(threaded.io()) catch return error.Io) |entry| {
            try out.appendSlice(gpa, entry.name);
            if (entry.kind == .directory) try out.append(gpa, '/');
            try out.append(gpa, '\n');
        }
        return out.toOwnedSlice(gpa);
    }

    /// What `rel` IS, resolved CONFINED — the stat counterpart to
    /// `read`/`write`/`append`/`list`, so an existence probe can never
    /// answer about something those four could not touch. Used by
    /// `wasm_host/fs.zig`'s `fsExists` under an `.fs_root` limit.
    ///
    /// The walk holds the final component's PARENT as an fd, and the leaf is
    /// stated relative to it without following (`fstatat` with
    /// `AT_SYMLINK_NOFOLLOW`; `statx` on Linux, via `std.Io`). That answers
    /// for ANYTHING that resolves — a directory, a device, a fifo (without
    /// blocking on a writer), a file the process cannot read — with no
    /// second lookup outside the held chain. A symlink leaf is refused
    /// (`error.Confined`) exactly as `read` refuses it — the symlink policy
    /// stays ONE policy across all five doors.
    pub fn kind(self: *const RootedFs, rel: [*:0]const u8) Error!Kind {
        return (try self.stat(rel)).kind;
    }

    /// `kind`, with the rest of the metadata — the confined half of
    /// `file.statFull`. ONE stat, one confinement, so a door that describes
    /// a path can never reach further than the doors that read it.
    ///
    /// `mode` is masked to permission bits (`file.mode_mask`) because the
    /// type already rides `kind`; stating it in both places is how the two
    /// come to disagree. Restated here rather than imported: this module
    /// deliberately knows nothing about `file.zig` (see `Kind`'s doc — its
    /// missing `.none` variant is the same boundary).
    pub fn stat(self: *const RootedFs, rel: [*:0]const u8) Error!Stat {
        var walk = try self.walkToParent(std.mem.span(rel));
        defer walk.close();
        // The single-threaded `Io` is a plain blocking syscall here; it is
        // what binds the platform's no-follow stat portably.
        var threaded: std.Io.Threaded = .init_single_threaded;
        const dir: std.Io.Dir = .{ .handle = walk.parent() };
        const st = dir.statFile(threaded.io(), walk.leaf orelse ".", .{ .follow_symlinks = false }) catch |err| return switch (err) {
            error.FileNotFound => error.NotFound,
            error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => error.Confined,
            else => error.Io,
        };
        const k: Kind = switch (st.kind) {
            .file => .file,
            .directory => .dir,
            .sym_link => return error.Confined,
            else => .other,
        };
        if (walk.dir_only and k != .dir) return error.Io; // `file/`: ENOTDIR
        return .{
            .kind = k,
            .mode = @as(u32, @truncate(@as(u64, @bitCast(@as(i64, st.permissions.toMode()))))) & mode_mask,
            .size = st.size,
            .mtime_ns = std.math.cast(i64, st.mtime.nanoseconds) orelse std.math.maxInt(i64),
            .nlink = std.math.cast(u32, st.nlink) orelse std.math.maxInt(u32),
        };
    }
};

/// The chain of directory fds one walk holds. Index 0 is the root (borrowed,
/// never closed here); every deeper entry was opened by `descend` and is
/// owned until `ascend` pops it or `close` releases the rest.
const Walk = struct {
    root_fd: i32,
    held: [max_depth]i32 = undefined,
    depth: usize = 0,
    leaf: ?[]const u8 = null,
    dir_only: bool,

    fn parent(self: *const Walk) i32 {
        return if (self.depth == 0) self.root_fd else self.held[self.depth - 1];
    }

    fn descend(self: *Walk, name: []const u8) Error!void {
        if (self.depth == max_depth) return error.Io;
        self.held[self.depth] = try openComponent(
            self.parent(),
            name,
            .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true },
            0,
        );
        self.depth += 1;
    }

    /// `..`: back to the directory already held one level up — never a
    /// fresh lookup of `..`, which a concurrent rename could redirect.
    fn ascend(self: *Walk) Error!void {
        if (self.depth == 0) return error.Confined;
        self.depth -= 1;
        _ = c.close(self.held[self.depth]);
    }

    fn close(self: *Walk) void {
        while (self.depth > 0) {
            self.depth -= 1;
            _ = c.close(self.held[self.depth]);
        }
    }
};

/// One `openat` of a single raw component beneath `dir_fd` (the caller puts
/// `NOFOLLOW` in `flags`), mapped to this module's errors.
fn openComponent(dir_fd: i32, name: []const u8, flags: c.O, mode: u32) Error!i32 {
    var buf: [max_component + 1]u8 = undefined;
    if (name.len > max_component) return error.Io;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const name_z: [*:0]const u8 = buf[0..name.len :0];
    while (true) {
        const rc = c.openat(dir_fd, name_z, flags, @as(c_uint, mode));
        return switch (c.errno(rc)) {
            .SUCCESS => rc,
            .INTR => continue,
            .NOENT => error.NotFound,
            // O_NOFOLLOW on a symlink → ELOOP; permission → EACCES/EPERM.
            .LOOP, .ACCES, .PERM => error.Confined,
            // A symlink opened O_DIRECTORY may report ENOTDIR before ELOOP:
            // still a symlink, still refused. A real non-directory is Io.
            .NOTDIR => if (isSymlink(dir_fd, name_z)) error.Confined else error.Io,
            else => error.Io,
        };
    }
}

/// `readlinkat` succeeds exactly on a symlink (EINVAL otherwise) — a stat
/// that needs no platform `struct stat`.
fn isSymlink(dir_fd: i32, name: [*:0]const u8) bool {
    var probe: [1]u8 = undefined;
    return c.readlinkat(dir_fd, name, &probe, probe.len) >= 0;
}

fn writeAll(fd: i32, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = c.write(fd, bytes[off..].ptr, bytes.len - off);
        const n: usize = switch (c.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => continue,
            else => return error.Io,
        };
        off += n;
    }
}

// ── tests ───────────────────────────────────────────────────────────

const t = std.testing;

/// Build a throwaway root dir under /tmp, keyed by pid and `tag` so parallel
/// runs don't collide, cleaned by the caller. Returns the NUL-terminated path.
fn makeTmpRoot(buf: []u8, tag: []const u8) ![:0]const u8 {
    const path = try std.fmt.bufPrintZ(buf, "/tmp/weft-rootedfs-{s}-{d}", .{ tag, c.getpid() });
    _ = c.rmdir(path.ptr); // best-effort clean from a prior run
    if (c.errno(c.mkdir(path.ptr, 0o755)) != .SUCCESS) return error.Mkdir;
    return path;
}

test "rooted_fs: confines reads/writes; rejects .., absolute, and symlink escape" {
    const gpa = t.allocator;
    var pbuf: [128]u8 = undefined;
    const root_path = try makeTmpRoot(&pbuf, "confine");

    var fs = try RootedFs.open(root_path.ptr);
    defer fs.close();

    // Cleanup: remove the files we create + the root dir.
    defer {
        _ = c.unlinkat(fs.root_fd, "hi.txt", 0);
        _ = c.unlinkat(fs.root_fd, "esc", 0);
        _ = c.rmdir(root_path.ptr);
    }

    // Write + read a confined file round-trips.
    try fs.write("hi.txt", "hello");
    const got = try fs.read(gpa, "hi.txt");
    defer gpa.free(got);
    try t.expectEqualStrings("hello", got);

    // A parent-escape is rejected by the walk (no fd above the root exists
    // to pop back to), not a lexical check we could get wrong.
    try t.expectError(error.Confined, fs.read(gpa, "../etc/hostname"));
    // An absolute path is also rejected.
    try t.expectError(error.Confined, fs.read(gpa, "/etc/hostname"));
    // A missing (but in-bounds) path is NotFound, distinct from Confined.
    try t.expectError(error.NotFound, fs.read(gpa, "nope.txt"));

    // A symlink pointing outside the root is refused (O_NOFOLLOW at every
    // step), closing the TOCTOU/symlink-swap hole a realpath check would
    // leave open.
    if (c.errno(c.symlinkat("/etc", fs.root_fd, "esc")) == .SUCCESS) {
        try t.expectError(error.Confined, fs.read(gpa, "esc/hostname"));
    }

    // list() sees the confined file and omits . / ..
    const listing = try fs.list(gpa, ".");
    defer gpa.free(listing);
    try t.expect(std.mem.indexOf(u8, listing, "hi.txt") != null);
    try t.expect(std.mem.indexOf(u8, listing, "..") == null);
}

test "rooted_fs: append creates-then-appends (confined), rejects the same escapes as write" {
    const gpa = t.allocator;
    var pbuf: [128]u8 = undefined;
    const root_path = try makeTmpRoot(&pbuf, "append");

    var fs = try RootedFs.open(root_path.ptr);
    defer fs.close();
    defer {
        _ = c.unlinkat(fs.root_fd, "log.txt", 0);
        _ = c.rmdir(root_path.ptr);
    }

    try fs.append("log.txt", "one\n"); // created, since absent
    try fs.append("log.txt", "two\n"); // appended, not truncated
    const got = try fs.read(gpa, "log.txt");
    defer gpa.free(got);
    try t.expectEqualStrings("one\ntwo\n", got);

    try t.expectError(error.Confined, fs.append("../escape.txt", "x"));
}

test "rooted_fs: the walk's edges — empty components, '.', trailing '/', in-root '..', symlinks at every position" {
    const gpa = t.allocator;
    var pbuf: [128]u8 = undefined;
    const root_path = try makeTmpRoot(&pbuf, "walk");

    var fs = try RootedFs.open(root_path.ptr);
    defer fs.close();
    if (c.errno(c.mkdirat(fs.root_fd, "sub", 0o755)) != .SUCCESS) return error.Mkdir;
    defer {
        _ = c.unlinkat(fs.root_fd, "sub/f.txt", 0);
        _ = c.unlinkat(fs.root_fd, "top.txt", 0);
        _ = c.unlinkat(fs.root_fd, "link-in", 0);
        _ = c.unlinkat(fs.root_fd, "dirlink", 0);
        _ = c.unlinkat(fs.root_fd, "sub", c.AT.REMOVEDIR);
        _ = c.rmdir(root_path.ptr);
    }
    try fs.write("sub/f.txt", "nested");
    try fs.write("top.txt", "top");

    // Empty components and `.` are no-ops.
    for ([_][*:0]const u8{ "sub//f.txt", "./sub/f.txt", "sub/./f.txt", ".//sub///f.txt" }) |p| {
        const got = try fs.read(gpa, p);
        defer gpa.free(got);
        try t.expectEqualStrings("nested", got);
    }
    // `..` that stays inside the root pops back to a held fd.
    const back = try fs.read(gpa, "sub/../top.txt");
    defer gpa.free(back);
    try t.expectEqualStrings("top", back);
    // ... but the popped component must still be a real directory.
    try t.expectError(error.NotFound, fs.read(gpa, "missing/../top.txt"));
    // `..` past the root, however it is reached, is refused.
    try t.expectError(error.Confined, fs.read(gpa, "sub/../../top.txt"));
    try t.expectError(error.Confined, fs.stat(".."));
    try t.expectError(error.Confined, fs.list(gpa, "sub/../.."));

    // `.`/`sub/..` name the root itself; a trailing `/` demands a directory.
    try t.expectEqual(Kind.dir, try fs.kind("."));
    try t.expectEqual(Kind.dir, try fs.kind("sub/.."));
    try t.expectEqual(Kind.dir, try fs.kind("sub/"));
    try t.expectEqual(Kind.file, try fs.kind("sub/f.txt"));
    try t.expectError(error.Io, fs.kind("top.txt/"));
    try t.expectError(error.Io, fs.read(gpa, "top.txt/"));
    const sub_listing = try fs.list(gpa, "sub/");
    defer gpa.free(sub_listing);
    try t.expectEqualStrings("f.txt\n", sub_listing);
    const root_listing = try fs.list(gpa, ".");
    defer gpa.free(root_listing);
    try t.expect(std.mem.indexOf(u8, root_listing, "sub/\n") != null);

    // The empty path names nothing.
    try t.expectError(error.NotFound, fs.read(gpa, ""));
    try t.expectError(error.NotFound, fs.stat(""));

    // A non-directory in the middle of the chain is not a directory to walk.
    try t.expectError(error.Io, fs.read(gpa, "top.txt/x"));

    // Symlinks are refused at EVERY position, even one pointing inside.
    if (c.errno(c.symlinkat("top.txt", fs.root_fd, "link-in")) == .SUCCESS) {
        try t.expectError(error.Confined, fs.read(gpa, "link-in"));
        try t.expectError(error.Confined, fs.stat("link-in"));
        try t.expectError(error.Confined, fs.write("link-in", "clobber"));
        try t.expectError(error.Confined, fs.append("link-in", "clobber"));
        const still = try fs.read(gpa, "top.txt");
        defer gpa.free(still);
        try t.expectEqualStrings("top", still);
    }
    if (c.errno(c.symlinkat("sub", fs.root_fd, "dirlink")) == .SUCCESS) {
        try t.expectError(error.Confined, fs.read(gpa, "dirlink/f.txt"));
        try t.expectError(error.Confined, fs.list(gpa, "dirlink"));
        try t.expectError(error.Confined, fs.list(gpa, "dirlink/"));
        try t.expectError(error.Confined, fs.kind("dirlink/.."));
    }
}

test "rooted_fs: stat reports metadata off the held parent without opening the leaf" {
    var pbuf: [128]u8 = undefined;
    const root_path = try makeTmpRoot(&pbuf, "stat");

    var fs = try RootedFs.open(root_path.ptr);
    defer fs.close();
    defer {
        _ = c.unlinkat(fs.root_fd, "locked.txt", 0);
        _ = c.rmdir(root_path.ptr);
    }
    try fs.write("locked.txt", "12345");
    // Unreadable to its owner, yet still describable (as O_PATH allowed).
    if (c.errno(c.fchmodat(fs.root_fd, "locked.txt", 0o000, 0)) != .SUCCESS) return error.Chmod;
    const st = try fs.stat("locked.txt");
    try t.expectEqual(Kind.file, st.kind);
    try t.expectEqual(@as(u32, 0), st.mode);
    try t.expectEqual(@as(u64, 5), st.size);
    try t.expectEqual(@as(u32, 1), st.nlink);
}

test {
    std.testing.refAllDecls(@This());
}
