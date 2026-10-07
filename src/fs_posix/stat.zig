//! What the provider knows about one filesystem object: its `Identity` and a
//! `Snapshot` of the metadata a revision is minted from.
//!
//! This is the ONE place the provider forks per OS, because the mechanism
//! genuinely differs and libc offers no common call that answers the question:
//!
//! - Linux: `statx` (`stat_linux.zig`). It is the only interface that reports
//!   birth time and the mount id, and glibc's `struct stat` has neither (Zig's
//!   `std.c` does not even bind glibc's `fstatat`, whose symbol versioning
//!   predates 2.33). Without birth time `Identity.eql` could never hold.
//! - Darwin: `fstatat`/`fstat` (below). `struct stat` carries
//!   `st_birthtimespec` directly; there is no mount id, and `st_dev` alone
//!   names the mount.
//!
//! Both produce the same `Snapshot`, so every caller above this file is one
//! portable implementation.

const std = @import("std");
const builtin = @import("builtin");
const fs = @import("weft_fs");

const contract = fs.contract;

pub const Identity = struct {
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
    pub fn locationEql(a: Identity, b: Identity) bool {
        return a.dev_major == b.dev_major and
            a.dev_minor == b.dev_minor and
            a.mount_id == b.mount_id and
            a.inode == b.inode;
    }

    /// Exact object identity is intentionally unavailable when either
    /// stat result lacks a birth time. We do not retain one fd per entry just
    /// to manufacture that guarantee; callers must report stale/ambiguous
    /// instead of accepting an unprovable replacement.
    pub fn eql(a: Identity, b: Identity) bool {
        return a.has_birth_time and b.has_birth_time and
            a.locationEql(b) and
            a.birth_sec == b.birth_sec and
            a.birth_nsec == b.birth_nsec;
    }
};

pub const Snapshot = struct {
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

const native = switch (builtin.os.tag) {
    .linux => @import("stat_linux.zig"),
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => darwin,
    else => @compileError("fs_posix stat: no implementation for this OS"),
};

/// Stat the raw leaf `name` beneath `dir_fd` without following a symlink.
pub fn at(dir_fd: i32, name: [*:0]const u8) contract.Error!Snapshot {
    return native.at(dir_fd, name);
}

/// Stat an already-open descriptor (never re-resolves a path).
pub fn ofFd(fd: i32) contract.Error!Snapshot {
    return native.ofFd(fd);
}

/// Map a stat errno to the contract's vocabulary; shared by both forks.
pub fn errorFor(err: std.c.E) contract.Error {
    return switch (err) {
        .NOENT => error.NotFound,
        .NOTDIR => error.NotDirectory,
        .ACCES, .PERM => error.PermissionDenied,
        .LOOP, .XDEV => error.Confined,
        .AGAIN, .BUSY => error.Busy,
        else => error.Io,
    };
}

pub fn kindOf(mode: u32) contract.Kind {
    const file_type = mode & std.c.S.IFMT;
    return if (file_type == std.c.S.IFREG)
        .regular
    else if (file_type == std.c.S.IFDIR)
        .directory
    else if (file_type == std.c.S.IFLNK)
        .symlink
    else
        .other;
}

const darwin = struct {
    fn at(dir_fd: i32, name: [*:0]const u8) contract.Error!Snapshot {
        var st: std.c.Stat = undefined;
        while (true) {
            const rc = std.c.fstatat(dir_fd, name, &st, std.c.AT.SYMLINK_NOFOLLOW);
            switch (std.c.errno(rc)) {
                .SUCCESS => return fromStat(st),
                .INTR => continue,
                else => |err| return errorFor(err),
            }
        }
    }

    fn ofFd(fd: i32) contract.Error!Snapshot {
        var st: std.c.Stat = undefined;
        while (true) {
            const rc = std.c.fstat(fd, &st);
            switch (std.c.errno(rc)) {
                .SUCCESS => return fromStat(st),
                .INTR => continue,
                else => |err| return errorFor(err),
            }
        }
    }

    /// `st_dev` is split the way `<sys/types.h>`'s `major()`/`minor()` do
    /// (8 bits / 24 bits). A filesystem that keeps no birth time reports a
    /// zero `st_birthtimespec`; that is "unknown", not the epoch.
    fn fromStat(st: std.c.Stat) Snapshot {
        const dev: u32 = @bitCast(st.dev);
        const birth = st.birthtimespec;
        const has_birth = birth.sec != 0 or birth.nsec != 0;
        return .{
            .identity = .{
                .dev_major = (dev >> 24) & 0xff,
                .dev_minor = dev & 0xffffff,
                .mount_id = 0,
                .inode = st.ino,
                .has_birth_time = has_birth,
                .birth_sec = if (has_birth) birth.sec else 0,
                .birth_nsec = if (has_birth) @intCast(birth.nsec) else 0,
            },
            .kind = kindOf(st.mode),
            .mode = @as(u32, st.mode) & 0o7777,
            .size = @intCast(st.size),
            .nlink = st.nlink,
            .modified_sec = st.mtimespec.sec,
            .modified_nsec = @intCast(st.mtimespec.nsec),
            .changed_sec = st.ctimespec.sec,
            .changed_nsec = @intCast(st.ctimespec.nsec),
        };
    }
};
