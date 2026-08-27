//! llm — a minimal agent adapter, the CLI variant (design §6.5: "CLI:
//! {proc, fs.read}"), a `.wasm` plugin (perms `{fs_write, proc, timer}`). It
//! writes the prompt to a temp file and pipes it to an `llm` CLI, streaming the
//! reply into a conversation buffer via the native `proc` surface. This is the
//! thin end of the agent story — no tools, no session peer, no net (that tier
//! needs `net.connect` + `spawnPeer`); it is the honest minimum that runs today.
//!
//! Every ask is its own CONVERSATION: it takes a fresh buffer (`*llm*`,
//! `*llm:2*`, …) and a prompt file named for it, so two asks in flight neither
//! overwrite each other's prompt nor land in each other's reply.

const std = @import("std");
const weft = @import("weft");

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
    const ordinal = weft.instanceOrdinal("llm") orelse return;
    var name_buf: [32]u8 = undefined;
    const buf = weft.instanceName("llm", ordinal, &name_buf) orelse return;
    var file_buf: [64]u8 = undefined;
    const prompt_file = std.fmt.bufPrint(&file_buf, "weft-llm-prompt-{d}.txt", .{ordinal}) catch return;
    if (!weft.fsWrite(prompt_file, prompt)) return;
    weft.runStr("buffer-create", buf);
    // The CLI reads the prompt from stdin; 2>&1 surfaces auth errors. `cmd`
    // defaults to the ordinary `llm` executable but is configuration data, so
    // a user can select another compatible adapter and tests can install a
    // hermetic one without a plugin- or harness-specific execution path.
    const configured = weft.config("cmd");
    const cli = if (configured.len > 0) configured else "llm";
    var cmd_buf: [2048]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s} < {s} 2>&1", .{ cli, prompt_file }) catch return;
    weft.procToBuffer(cmd, buf, 0);
}

/// Ask with the prompt given as arg0.
fn ask() void {
    run(weft.argStr(0) orelse return);
}
/// Ask with the current line as the prompt (a quick scratch query).
fn askLine() void {
    const l = weft.lineAt(weft.cursor());
    var prompt_buf: [4096]u8 = undefined;
    const line = weft.slice(l.start, l.end);
    const n = @min(line.len, prompt_buf.len);
    @memcpy(prompt_buf[0..n], line[0..n]); // copy — minting the buffer reuses the read scratch
    run(prompt_buf[0..n]);
}
