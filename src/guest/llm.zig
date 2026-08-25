//! llm — a minimal agent adapter, the CLI variant (design §6.5: "CLI:
//! {proc, fs.read}"), a `.wasm` plugin (perms `{fs_write, proc, timer}`). It
//! writes the prompt to a temp file and pipes it to an `llm` CLI, streaming the
//! reply into an *llm* buffer via the native `proc` surface. This is the thin
//! end of the agent story — no tools, no session peer, no net (that tier needs
//! `net.connect` + `spawnPeer`); it is the honest minimum that runs today.

const std = @import("std");
const weft = @import("weft");

const prompt_file = "weft-llm-prompt.txt";

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "llm-ask", .handler = ask },
    .{ .name = "llm-ask-line", .handler = askLine },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.fs_write);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

fn run(prompt: []const u8) void {
    if (prompt.len == 0) return;
    if (!weft.fsWrite(prompt_file, prompt)) return;
    weft.runStr("buffer-create", "*llm*");
    // The CLI reads the prompt from stdin; 2>&1 surfaces auth errors. `cmd`
    // defaults to the ordinary `llm` executable but is configuration data, so
    // a user can select another compatible adapter and tests can install a
    // hermetic one without a plugin- or harness-specific execution path.
    const configured = weft.config("cmd");
    const cli = if (configured.len > 0) configured else "llm";
    var cmd_buf: [2048]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s} < {s} 2>&1", .{ cli, prompt_file }) catch return;
    weft.procToBuffer(cmd, "*llm*");
}

/// Ask with the prompt given as arg0.
fn ask() void {
    run(weft.argStr(0) orelse return);
}
/// Ask with the current line as the prompt (a quick scratch query).
fn askLine() void {
    const l = weft.lineAt(weft.cursor());
    run(weft.slice(l.start, l.end));
}
