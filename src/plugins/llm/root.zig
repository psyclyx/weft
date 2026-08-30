//! llm — a minimal agent adapter, the CLI variant (design §6.5: "CLI:
//! {proc, fs.read}"), a `.wasm` plugin (perms `{proc, timer}`). It SPOOLS the
//! prompt — hands it to `weft.procSpool`, which lands it in a temp file the
//! HOST names and removes — and pipes that to an `llm` CLI, streaming the reply
//! into a conversation buffer. This is the thin end of the agent story — no
//! tools, no session peer, no net (that tier needs `net.connect` +
//! `spawnPeer`); it is the honest minimum that runs today.
//!
//! Every ask is its own CONVERSATION: it takes a fresh buffer (`*llm*`,
//! `*llm:2*`, …) and its own spooled prompt, so two asks in flight neither
//! overwrite each other's prompt nor land in each other's reply.
//!
//! No `fs_write`: the plugin never names a path, so it cannot choose where the
//! prompt lands, cannot leave it behind, and cannot depend on the shell's
//! working directory agreeing with anything (`doc/place.md` §4.2).

const std = @import("std");
const weft = @import("weft");

/// `params` is the command's argument shape, written the way a person reads
/// it back (`describeCommand`): the palette shows it beside the row, the `:`
/// line hints it while you type, and it is what gets ASKED for when a call
/// arrives short.
const Cmd = struct {
    name: []const u8,
    handler: *const fn () void,
    params: []const u8 = "",
    summary: []const u8 = "",
};
const cmds = [_]Cmd{
    .{ .name = "llm-ask", .handler = ask, .params = "prompt", .summary = "Ask the configured LLM CLI; the reply lands in its own buffer." },
    .{ .name = "llm-ask-line", .handler = askLine, .summary = "Ask using the current line as the prompt." },
};

export fn describe() void {
    for (cmds) |c| weft.describeCommand(c.name, c.params, c.summary);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// The prompt, copied out of whichever shim scratch it arrived in — `argStr`'s
/// and `slice`'s buffers are both reused by the buffer-naming reads below, and
/// the prompt has to outlive all of them.
var prompt_store: [1 << 14]u8 = undefined;

fn run(prompt: []const u8) void {
    if (prompt.len == 0) return;
    const n = @min(prompt.len, prompt_store.len);
    @memcpy(prompt_store[0..n], prompt[0..n]);
    const ordinal = weft.instanceOrdinal("llm") orelse return;
    var name_buf: [32]u8 = undefined;
    const buf = weft.instanceName("llm", ordinal, &name_buf) orelse return;
    weft.runStr("buffer-create", buf);
    // The CLI reads the prompt from stdin; 2>&1 surfaces auth errors. `cmd`
    // defaults to the ordinary `llm` executable but is configuration data, so
    // a user can select another compatible adapter and tests can install a
    // hermetic one without a plugin- or harness-specific execution path.
    const configured = weft.config("cmd");
    const cli = if (configured.len > 0) configured else "llm";
    var cmd_buf: [2048]u8 = undefined;
    // `{}` is the spooled prompt: the host writes it, names it, and deletes it.
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s} < {{}} 2>&1", .{cli}) catch return;
    weft.procSpool(cmd, prompt_store[0..n], buf, 0);
}

/// Ask with the prompt given as arg0.
fn ask() void {
    run(weft.argStr(0) orelse return);
}
/// Ask with the current line as the prompt (a quick scratch query).
fn askLine() void {
    const l = weft.lineAt(weft.cursor());
    run(weft.slice(l.start, l.end)); // `run` copies out of the read scratch
}
