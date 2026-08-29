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

var id_insert: u32 = 0;

export fn describe() void {
    weft.declareCommand("insert-shell");
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}

export fn init() void {
    id_insert = weft.register("insert-shell");
}

export fn on_command(id: u32) void {
    _ = id;
    const cmd = weft.argStr(0) orelse return;
    weft.shellInsert(cmd);
}
