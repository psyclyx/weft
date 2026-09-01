//! shell — "insert command output", a `.wasm` plugin. `insert-shell "<cmd>"`
//! runs the command off the frame thread and inserts its stdout at the cursor
//! when it finishes, resolved through its CRDT identity if the buffer moved,
//! authored as the plugin peer. Perms: proc (it shells out) + timer (the async
//! delivery), declared up front.
//!
//! A guest cannot hold the proc body itself — its store is frame-bound, so
//! there is no off-thread work body to put it in. The membrane offers
//! `shellInsert` instead: the same async target and authority, with the proc
//! body host-side. The design anticipated this: "route proc through the
//! perm-checked host import."

const weft = @import("weft");

const cmds = [_]weft.CommandEntry{
    .{
        .name = "insert-shell",
        .call = weft.thunk(insertShell),
        .params = "command",
        .summary = "Run a shell command and insert its output at the cursor.",
    },
};
comptime {
    weft.plugin(&cmds, .{ .perms = &.{ .proc, .timer } }).exportAll();
}

/// The command's argument arrives as a parameter, owned for this call — where
/// it used to be a slice into the shim's shared arg scratch that any other read
/// door would have overwritten underneath us.
fn insertShell(cmd: []const u8) void {
    weft.shellInsert(cmd);
}
