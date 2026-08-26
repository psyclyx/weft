//! fs_limit — a guest fixture (doc/contextual-workspace-architecture.md
//! §13.5, task #8's item 1: proving `.fs_root` limit enforcement THROUGH a
//! real wasm guest, not just the in-process semantic bodies). Requests
//! fs_read + fs_write, then exposes each path-taking primitive as a
//! command reading its path (and, for write, its content) from the
//! command's own args — so the host-side test controls exactly which path
//! to try against whichever grant it minted (in-root, out-of-root, a `..`
//! traversal) without needing a separate fixture per scenario. Mirrors
//! `deny.zig`'s "a guest built for the test it backs" pattern, one door
//! over (limit-gating, not perm-gating): a call that's out of the grant's
//! root must TRAP, never hand back a fake result the guest could observe
//! and keep running past.

const weft = @import("weft");

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "try-read", .handler = tryRead },
    .{ .name = "try-write", .handler = tryWrite },
    .{ .name = "try-exists", .handler = tryExists },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.fs_read);
    weft.requestPerm(.fs_write);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// arg0 = path. Result: the file's bytes, or "<absent>" for a mundane miss
/// (not found) — distinct from a trap, which never returns at all.
fn tryRead() void {
    const path = weft.argStr(0) orelse return;
    const content = weft.fsRead(path) orelse {
        weft.setResultStr("<absent>");
        return;
    };
    weft.setResultStr(content);
}

// `argStr` reuses ONE shared scratch buffer — arg0 (the path) must be copied
// out before arg1 (the content) overwrites it, exactly like notes.zig's
// `capture()`.
var path_buf: [1024]u8 = undefined;

/// arg0 = path, arg1 = content. Result: 1 on success, 0 on a mundane failure.
fn tryWrite() void {
    const raw_path = weft.argStr(0) orelse return;
    const n = @min(raw_path.len, path_buf.len);
    @memcpy(path_buf[0..n], raw_path[0..n]);
    const path = path_buf[0..n];
    const content = weft.argStr(1) orelse "";
    weft.setResultInt(if (weft.fsWrite(path, content)) 1 else 0);
}

/// arg0 = path. Result: the `FsKind` ordinal (0 none / 1 file / 2 dir / 3 other).
fn tryExists() void {
    const path = weft.argStr(0) orelse return;
    weft.setResultInt(@intFromEnum(weft.fsExists(path)));
}
