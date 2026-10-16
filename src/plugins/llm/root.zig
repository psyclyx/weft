//! llm — a minimal agent adapter, the CLI variant (design §6.5: "CLI:
//! {proc, fs.read}"), a `.wasm` plugin (perms `{proc, timer}`). It hands the
//! prompt to an `llm` CLI on its stdin and streams the reply into a
//! conversation buffer as the CLI writes it (`output.show` with `input`). This
//! is the thin end of the agent story — no tools, no session peer, no net
//! (that tier needs `net.connect` + `spawnPeer`); it is the honest minimum that
//! runs today.
//!
//! Every ask is its own CONVERSATION: it takes a fresh buffer (`*llm*`,
//! `*llm:2*`, …) and its own process and stdin, so two asks in flight neither
//! overwrite each other's prompt nor land in each other's reply.
//!
//! No `fs_write`: the plugin never names a path, so it cannot choose where the
//! prompt lands, cannot leave it behind, and cannot depend on the shell's
//! working directory agreeing with anything (`doc/place.md` §4.2).

const std = @import("std");
const weft = @import("weft");
const output = @import("weft_output");

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
const cmds = [_]weft.CommandEntry{
    .{ .name = "llm.ask", .call = ask, .arity = .whole, .params = "prompt", .summary = "Ask the configured LLM command a question, with the reply in its own buffer.", .label = "Ask LLM", .menu = "Run/Tools", .group = "llm", .order = 1, .icon = "sparkles", .prompts = true },
    .{ .name = "llm.ask-line", .arity = .one, .call = askLine, .summary = "Ask the configured LLM command, using the current line as the prompt.", .label = "Ask LLM with Line", .menu = "Run/Tools", .group = "llm", .order = 2, .icon = "sparkles" },
    .{ .name = "llm.visit", .call = output.visit, .arity = .one, .summary = "Open the location the focused reply row names.", .internal = true },
};

fn initExtra() void {
    output.installMode("llm-reply", "llm.visit");
}

fn describeExtra() void {
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
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
    // The CLI reads the prompt from stdin; its stderr (an auth error) is part
    // of the reply. `cmd` defaults to the ordinary `llm` executable but is
    // configuration data — words, no shell — so a user can select another
    // compatible adapter and tests can install a hermetic one without a
    // plugin- or harness-specific execution path.
    const configured = weft.config("cmd");
    var words: weft.Argv = .{};
    const argv = weft.argvWords(if (configured.len > 0) configured else "llm", &words);
    if (words.full or argv.len == 0) return weft.echo("llm: the configured command is empty or too long");
    output.show(argv, buf, "llm-reply", .{ .input = prompt_store[0..n], .want_err = true });
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

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra, .init = initExtra }).exportAll();
}
