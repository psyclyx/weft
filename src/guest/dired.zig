//! dired — a directory editor (dired / dirvish / :Explore), a `.wasm` plugin
//! over `proc` + a tool buffer + its OWN keymap mode. `dired` lists a directory
//! into `*dired*` and puts the buffer in the `dired` mode: Return opens the
//! entry under the cursor (descend into a directory, or open a file), `-` goes
//! up a level, `g` refreshes. The mode falls back to `normal`, so vim motions
//! still navigate the listing. perms `{proc}` (it shells `ls`; a locus-routed
//! remote listing rides the same command shape once fs.list lands).

const std = @import("std");
const weft = @import("weft.zig");

const dired_buf = "*dired*";
/// The directory currently listed (paths are built relative to it).
var cwd_buf: [1024]u8 = undefined;
var cwd_len: usize = 0;
/// Which locus we're browsing: local ("here") or the connected peer's shared
/// root. `dired` opens local; `dired-peer` opens the peer (dired on a coworker's
/// tree — the locus-respect the design wants).
var peer_mode: bool = false;

fn cwd() []const u8 {
    return cwd_buf[0..cwd_len];
}
fn setCwd(path: []const u8) void {
    cwd_len = @min(path.len, cwd_buf.len);
    @memcpy(cwd_buf[0..cwd_len], path[0..cwd_len]);
}

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "dired", .handler = open },
    .{ .name = "dired-peer", .handler = openPeer },
    .{ .name = "dired-open", .handler = openEntry },
    .{ .name = "dired-up", .handler = up },
    .{ .name = "dired-refresh", .handler = refresh },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.fs_read);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
    // The dired keymap: its own verbs, vim motions inherited from normal.
    weft.setFallback("dired", "normal");
    weft.bindKey("dired", "Return", "dired-open");
    weft.bindKey("dired", "minus", "dired-up");
    weft.bindKey("dired", "g", "dired-refresh");
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// List `dir` into `*dired*` and enter the dired mode. Locus-routed via
/// `fs.list` ("here" = local): no subprocess, and the same call lists a peer's
/// shared root once the collab transport is wired. Directories keep a trailing
/// `/` — the marker `openEntry` uses to decide descend vs open.
fn list(dir: []const u8) void {
    setCwd(dir);
    weft.runStr("buffer-create", dired_buf); // create/focus the tool buffer
    if (peer_mode) {
        // Remote (peer) listing is async: it lands in *dired* a few frames
        // later via the session's RemoteFs; no blocking round-trip here.
        _ = weft.fsListAsync("peer", dir, dired_buf);
    } else {
        const listing = weft.fsList("here", dir) orelse return; // borrows scratch
        weft.edit(.{ .start = 0, .end = weft.byteLen() }, listing);
        weft.jump(0);
    }
    weft.setMode("dired");
}

fn open() void {
    peer_mode = false;
    list(".");
}
fn openPeer() void {
    peer_mode = true;
    list(".");
}
fn refresh() void {
    list(cwd());
}

/// Go up a level: the parent of the listed directory. Descent always builds
/// `cwd/name`, so the listed path has a slash after the first step; trim the
/// last component (a leading "." with no slash goes to "..").
fn up() void {
    const trimmed = std.mem.trimEnd(u8, cwd(), "/");
    const parent = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i|
        (if (i == 0) trimmed[0..1] else trimmed[0..i])
    else
        "..";
    var buf: [1024]u8 = undefined;
    const n = @min(parent.len, buf.len);
    @memcpy(buf[0..n], parent[0..n]);
    list(buf[0..n]);
}

/// Open the entry on the current line: descend into a directory (trailing `/`)
/// or open a file, both relative to the listed directory.
fn openEntry() void {
    const line = weft.lineAt(weft.cursor());
    const raw = weft.slice(line.start, line.end); // borrows the shared scratch
    var namebuf: [512]u8 = undefined;
    const n = @min(raw.len, namebuf.len);
    @memcpy(namebuf[0..n], raw[0..n]); // copy out before building the path
    const entry = std.mem.trim(u8, namebuf[0..n], " \t\r\n");
    if (entry.len == 0) return;

    var pathbuf: [1600]u8 = undefined;
    const full = std.fmt.bufPrint(&pathbuf, "{s}/{s}", .{ cwd(), entry }) catch return;
    if (std.mem.endsWith(u8, entry, "/")) {
        list(full[0 .. full.len - 1]); // descend (drop the trailing marker)
    } else {
        weft.runStr("open", full);
    }
}
