//! rooted_fs — a filesystem confined to a root directory via
//! `openat2(RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS)`. Every path is resolved
//! relative to a held root dir-fd IN THE KERNEL, atomically: a `..` component,
//! an absolute path, or a symlink that would leave the root fails the open —
//! no lexical `..`-stripping, no realpath, no TOCTOU window between a check and
//! the open. This is the confinement the `.peer` fs server (design Part D)
//! needs so a connected client can never read outside the host's shared root.
//!
//! Linux-only (openat2 is a Linux syscall); the collab host is Linux.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

// open_how.resolve flags (uapi/linux/openat2.h). Not yet in std.os.linux.
const RESOLVE_NO_SYMLINKS: u64 = 0x04;
const RESOLVE_BENEATH: u64 = 0x08;

const open_how = extern struct {
    flags: u64,
    mode: u64 = 0,
    resolve: u64,
};

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

pub const RootedFs = struct {
    root_fd: i32,

    /// Open `root` (cwd-relative or absolute) as the confinement root.
    pub fn open(root: [*:0]const u8) Error!RootedFs {
        const flags: linux.O = .{ .DIRECTORY = true, .CLOEXEC = true };
        const rc = linux.openat(linux.AT.FDCWD, root, flags, 0);
        if (linux.errno(rc) != .SUCCESS) return error.OpenRoot;
        return .{ .root_fd = @intCast(rc) };
    }

    pub fn close(self: *RootedFs) void {
        if (self.root_fd >= 0) _ = linux.close(self.root_fd);
        self.root_fd = -1;
    }

    /// openat2 a NUL-terminated path relative to the root, confined beneath it.
    /// An escape (`..`, absolute, or symlink out) returns error.Confined; a
    /// missing path returns error.NotFound.
    fn openBeneath(self: *const RootedFs, rel: [*:0]const u8, o_flags: linux.O, mode: u64) Error!i32 {
        var how: open_how = .{
            .flags = @as(u64, @as(u32, @bitCast(o_flags))),
            .mode = mode,
            .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS,
        };
        const rc = linux.syscall4(
            .openat2,
            @as(usize, @bitCast(@as(isize, self.root_fd))),
            @intFromPtr(rel),
            @intFromPtr(&how),
            @sizeOf(open_how),
        );
        return switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .NOENT => error.NotFound,
            // RESOLVE_BENEATH escape → EXDEV; RESOLVE_NO_SYMLINKS → ELOOP;
            // absolute path under BENEATH → EXDEV; permission → EACCES.
            .XDEV, .LOOP, .ACCES, .PERM => error.Confined,
            else => error.Io,
        };
    }

    /// Read the whole file at `rel` (confined) into an owned slice.
    pub fn read(self: *const RootedFs, gpa: Allocator, rel: [*:0]const u8) Error![]u8 {
        const fd = try self.openBeneath(rel, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        defer _ = linux.close(fd);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const rc = linux.read(fd, &buf, buf.len);
            const n = switch (linux.errno(rc)) {
                .SUCCESS => rc,
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
        defer _ = linux.close(fd);
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = linux.write(fd, bytes[off..].ptr, bytes.len - off);
            const n = switch (linux.errno(rc)) {
                .SUCCESS => rc,
                .INTR => continue,
                else => return error.Io,
            };
            off += n;
        }
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
        defer _ = linux.close(fd);
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = linux.write(fd, bytes[off..].ptr, bytes.len - off);
            const n = switch (linux.errno(rc)) {
                .SUCCESS => rc,
                .INTR => continue,
                else => return error.Io,
            };
            off += n;
        }
    }

    /// List the directory at `rel` (confined), returning names newline-joined
    /// (owned). Directories keep a trailing `/`, so a consumer (files) can tell
    /// them apart. Order is filesystem order.
    pub fn list(self: *const RootedFs, gpa: Allocator, rel: [*:0]const u8) Error![]u8 {
        const fd = try self.openBeneath(rel, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        defer _ = linux.close(fd);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var buf: [8192]u8 align(8) = undefined;
        while (true) {
            const rc = linux.syscall3(.getdents64, @as(usize, @bitCast(@as(isize, fd))), @intFromPtr(&buf), buf.len);
            const n = switch (linux.errno(rc)) {
                .SUCCESS => rc,
                .INTR => continue,
                else => return error.Io,
            };
            if (n == 0) break;
            var i: usize = 0;
            while (i < n) {
                const d: *align(1) const linux.dirent64 = @ptrCast(&buf[i]);
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&d.name)), 0);
                i += d.reclen;
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                try out.appendSlice(gpa, name);
                if (d.type == linux.DT.DIR) try out.append(gpa, '/');
                try out.append(gpa, '\n');
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// What `rel` IS, resolved CONFINED — the stat counterpart to
    /// `read`/`write`/`append`/`list`, so an existence probe can never
    /// answer about something those four could not touch. Used by
    /// `wasm_host/fs.zig`'s `fsExists` under an `.fs_root` limit.
    ///
    /// `O_PATH` is the whole trick: it opens ANYTHING that resolves — a
    /// directory, a device, a fifo (without blocking on a writer), a file
    /// the process cannot read — purely to name it, with no side effects.
    /// `statx(AT_EMPTY_PATH, STATX_TYPE)` on that descriptor then reads the
    /// type off the already-confined fd, which is why no path is ever
    /// re-resolved outside the kernel's atomic `openat2` (no TOCTOU window,
    /// no second lookup to get wrong).
    ///
    /// Deliberately NOT `O_NOFOLLOW`: with `RESOLVE_NO_SYMLINKS`, adding it
    /// would let a TRAILING symlink open as the link itself and report
    /// `.other`. Without it, a symlink anywhere in the chain is refused
    /// (`ELOOP` → `error.Confined`) exactly as `read` refuses it — the
    /// symlink policy stays ONE policy across all five doors.
    pub fn kind(self: *const RootedFs, rel: [*:0]const u8) Error!Kind {
        return (try self.stat(rel)).kind;
    }

    /// `kind`, with the rest of the metadata — the confined half of
    /// `file.statFull`. ONE statx, one confinement, so a door that describes
    /// a path can never reach further than the doors that read it.
    ///
    /// `mode` is masked to permission bits (`file.mode_mask`) because the
    /// type already rides `kind`; stating it in both places is how the two
    /// come to disagree. Restated here rather than imported: this module
    /// deliberately knows nothing about `file.zig` (see `Kind`'s doc — its
    /// missing `.none` variant is the same boundary).
    pub fn stat(self: *const RootedFs, rel: [*:0]const u8) Error!Stat {
        const fd = try self.openBeneath(rel, .{ .ACCMODE = .RDONLY, .PATH = true, .CLOEXEC = true }, 0);
        defer _ = linux.close(fd);
        var st: linux.Statx = undefined;
        const want: linux.STATX = .{ .TYPE = true, .MODE = true, .SIZE = true, .MTIME = true, .NLINK = true };
        const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, want, &st);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .NOENT => return error.NotFound,
            .ACCES, .PERM => return error.Confined,
            else => return error.Io,
        }
        const file_type = st.mode & linux.S.IFMT;
        return .{
            .kind = if (file_type == linux.S.IFREG) .file else if (file_type == linux.S.IFDIR) .dir else .other,
            .mode = @as(u32, st.mode) & mode_mask,
            .size = st.size,
            .mtime_ns = st.mtime.sec *| std.time.ns_per_s +| @as(i64, st.mtime.nsec),
            .nlink = st.nlink,
        };
    }
};

// ── tests ───────────────────────────────────────────────────────────

const t = std.testing;

/// Build a throwaway root dir under /tmp, keyed by pid so parallel runs don't
/// collide, cleaned by the caller. Returns the NUL-terminated path.
fn makeTmpRoot(buf: []u8) ![:0]const u8 {
    const pid = linux.getpid();
    const path = try std.fmt.bufPrintZ(buf, "/tmp/weft-rootedfs-{d}", .{pid});
    _ = linux.rmdir(path.ptr); // best-effort clean from a prior run
    if (linux.errno(linux.mkdir(path.ptr, 0o755)) != .SUCCESS) return error.Mkdir;
    return path;
}

test "rooted_fs: confines reads/writes; rejects .., absolute, and symlink escape" {
    const gpa = t.allocator;
    var pbuf: [128]u8 = undefined;
    const root_path = try makeTmpRoot(&pbuf);

    var fs = try RootedFs.open(root_path.ptr);
    defer fs.close();

    // Cleanup: remove the files we create + the root dir.
    defer {
        _ = linux.unlinkat(fs.root_fd, "hi.txt", 0);
        _ = linux.unlinkat(fs.root_fd, "esc", 0);
        _ = linux.rmdir(root_path.ptr);
    }

    // Write + read a confined file round-trips.
    try fs.write("hi.txt", "hello");
    const got = try fs.read(gpa, "hi.txt");
    defer gpa.free(got);
    try t.expectEqualStrings("hello", got);

    // A parent-escape is rejected in the kernel (EXDEV → Confined), not a
    // lexical check we could get wrong.
    try t.expectError(error.Confined, fs.read(gpa, "../etc/hostname"));
    // An absolute path under RESOLVE_BENEATH is also rejected.
    try t.expectError(error.Confined, fs.read(gpa, "/etc/hostname"));
    // A missing (but in-bounds) path is NotFound, distinct from Confined.
    try t.expectError(error.NotFound, fs.read(gpa, "nope.txt"));

    // A symlink pointing outside the root is refused (RESOLVE_NO_SYMLINKS),
    // closing the TOCTOU/symlink-swap hole a realpath check would leave open.
    if (linux.errno(linux.symlinkat("/etc", fs.root_fd, "esc")) == .SUCCESS) {
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
    const root_path = try makeTmpRoot(&pbuf);

    var fs = try RootedFs.open(root_path.ptr);
    defer fs.close();
    defer {
        _ = linux.unlinkat(fs.root_fd, "log.txt", 0);
        _ = linux.rmdir(root_path.ptr);
    }

    try fs.append("log.txt", "one\n"); // created, since absent
    try fs.append("log.txt", "two\n"); // appended, not truncated
    const got = try fs.read(gpa, "log.txt");
    defer gpa.free(got);
    try t.expectEqualStrings("one\ntwo\n", got);

    try t.expectError(error.Confined, fs.append("../escape.txt", "x"));
}

test {
    std.testing.refAllDecls(@This());
}
