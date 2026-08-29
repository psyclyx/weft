//! spool (wasm) — the gate guest for `wl_proc_spool` (`doc/place.md` §4.2).
//!
//! It holds `{proc, timer}` and NOTHING else: no `fs_read`, no `fs_write`. So
//! every claim the door makes is claimed by a guest that could not write, read
//! back, or clean up a file even if it wanted to.
//!
//! Each command spools an input and asks the shell to report BOTH what it read
//! back out of `{}` and the path it was handed, so the host-side test can then
//! check that path names nothing. That is the honest shape of "the guest cannot
//! keep the temp": even a guest that goes out of its way to leak the path — as
//! these commands deliberately do, through their own command's stdout — is
//! holding the name of a file that no longer exists by the time it can read it.

const weft = @import("weft");

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "spool-ok", .handler = ok },
    .{ .name = "spool-fail", .handler = fail },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
    // Deliberately no fs perm: the whole point of the spool is that handing a
    // subprocess a real file needs neither fs_write nor fs_read.
}

export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}

export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

// The commands below use SHELL BUILTINS only (`read`, `printf`). A plugin's
// children inherit the host environ, which the unit-test `Env` leaves empty —
// so `cat` and friends are not on any PATH there, and a gate that needed them
// would pass vacuously by producing no output at all.

/// A command that SUCCEEDS: echo the spooled bytes back, plus the path they
/// arrived at, so the host-side gate can go looking for it.
fn ok() void {
    weft.procSpool("read -r l < {}; printf 'in=%s at=%s' \"$l\" '{}'", "hello spool\n", "*spool*", 0);
}

/// The same, but the command then FAILS. stdout still lands (a fill is what the
/// command said, not whether it succeeded), so the test can read the path out
/// of it and prove the temp is gone on the failure path too.
fn fail() void {
    weft.procSpool("read -r l < {}; printf 'in=%s at=%s' \"$l\" '{}'; exit 3", "goodbye spool\n", "*spool-fail*", 0);
}
