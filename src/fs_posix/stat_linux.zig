//! The Linux half of `stat.zig`: `statx`, the one interface that reports
//! birth time (`STATX_BTIME`) and the mount id (`STATX_MNT_ID`) an exact
//! `Identity` needs. Everything else in the provider is portable libc.

comptime {
    if (@import("builtin").os.tag != .linux) @compileError("stat_linux.zig is Linux-only");
}

const std = @import("std");
const fs = @import("weft_fs");
const stat = @import("stat.zig");

const contract = fs.contract;
const linux = std.os.linux;

pub fn at(dir_fd: i32, name: [*:0]const u8) contract.Error!stat.Snapshot {
    return statxAt(dir_fd, name, linux.AT.SYMLINK_NOFOLLOW | linux.AT.NO_AUTOMOUNT);
}

pub fn ofFd(fd: i32) contract.Error!stat.Snapshot {
    return statxAt(fd, "", linux.AT.EMPTY_PATH | linux.AT.SYMLINK_NOFOLLOW | linux.AT.NO_AUTOMOUNT);
}

fn statxAt(fd: i32, name: [*:0]const u8, flags: u32) contract.Error!stat.Snapshot {
    var st: linux.Statx = undefined;
    var mask = linux.STATX.BASIC_STATS;
    mask.MNT_ID = true;
    mask.BTIME = true;
    while (true) {
        const rc = linux.statx(fd, name, flags, mask, &st);
        switch (linux.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => |err| return stat.errorFor(err),
        }
    }
    return .{
        .identity = .{
            .dev_major = st.dev_major,
            .dev_minor = st.dev_minor,
            .mount_id = if (st.mask.MNT_ID) st.mnt_id else 0,
            .inode = st.ino,
            .has_birth_time = st.mask.BTIME,
            .birth_sec = if (st.mask.BTIME) st.btime.sec else 0,
            .birth_nsec = if (st.mask.BTIME) st.btime.nsec else 0,
        },
        .kind = stat.kindOf(st.mode),
        .mode = st.mode & 0o7777,
        .size = st.size,
        .nlink = st.nlink,
        .modified_sec = st.mtime.sec,
        .modified_nsec = st.mtime.nsec,
        .changed_sec = st.ctime.sec,
        .changed_nsec = st.ctime.nsec,
    };
}
