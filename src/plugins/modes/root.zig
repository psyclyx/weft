//! modes — language activation (design §3/§6.2), a `.wasm` plugin. When a
//! buffer takes focus the host calls `on_activate`; modes reads the path,
//! detects the language by extension, and echoes it (a hook a richer mode set
//! layers language keymaps/facts onto). It also provides `modes.run`, a
//! self-adapting "run this file" that picks the interpreter by extension —
//! language awareness in the command, so it is always correct. perms
//! `{proc, timer}`.

const std = @import("std");
const weft = @import("weft");
const output = @import("weft_output");

var echo_buf: [128]u8 = undefined;

const Lang = struct { ext: []const u8, name: []const u8, run: []const u8 };
/// (extension, display language, "run this file" command; `{}` = the path).
const langs = [_]Lang{
    .{ .ext = ".zig", .name = "zig", .run = "zig run {}" },
    .{ .ext = ".py", .name = "python", .run = "python3 {}" },
    .{ .ext = ".js", .name = "javascript", .run = "node {}" },
    .{ .ext = ".ts", .name = "typescript", .run = "node {}" },
    .{ .ext = ".rs", .name = "rust", .run = "" },
    .{ .ext = ".go", .name = "go", .run = "go run {}" },
    .{ .ext = ".sh", .name = "shell", .run = "sh {}" },
    .{ .ext = ".rb", .name = "ruby", .run = "ruby {}" },
    .{ .ext = ".lua", .name = "lua", .run = "lua {}" },
    .{ .ext = ".nix", .name = "nix", .run = "" },
    .{ .ext = ".md", .name = "markdown", .run = "" },
    .{ .ext = ".c", .name = "c", .run = "" },
    .{ .ext = ".h", .name = "c", .run = "" },
};

fn langFor(path: []const u8) ?Lang {
    inline for (langs) |l| {
        if (std.mem.endsWith(u8, path, l.ext)) return l;
    }
    return null;
}

const cmds = [_]weft.CommandEntry{
    .{ .name = "modes.run", .arity = .whole, .call = langRun, .summary = "Run the current file with its language's runner.", .label = "Run File", .menu = "Run", .group = "run", .order = 1, .icon = "play" },
    .{ .name = "modes.visit", .call = output.visit, .arity = .one, .summary = "Open the location the focused run row names.", .internal = true },
};

fn initExtra() void {
    output.installMode("modes-run", "modes.visit");
}

fn describeExtra() void {
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}

/// The host calls this when a buffer takes focus (design §3). BACKGROUND
/// (`on_activate` carries no per-call ctx at all — `wasm_host/commands.zig`'s
/// classification doc), so this can no longer `weft.echo` the detected
/// language directly: `wl_echo` is head-gated (task #19 item 4) and there is
/// no dispatching head to route through here (unlike `on_fill`/`on_poll`,
/// `on_activate` has no natural "the async thing that just landed" moment to
/// defer through a self-dispatched command either — it fires synchronously
/// off the SAME buffer.switch that would make the echo redundant a frame
/// later anyway). Downgraded to `weft.log` — still observable (the process
/// log), no longer a false promise of a user-visible echo this entry can't
/// honor. A per-head-aware activation echo is real future work, not solved
/// here (see `wasm_host/commands.zig`'s doc for the same "no ctx flows in"
/// limitation `on_menu` documents).
fn on_activate() callconv(.c) void {
    const path = weft.activatePath();
    const l = langFor(path) orelse return;
    const msg = std.fmt.bufPrint(&echo_buf, "mode: {s}", .{l.name}) catch return;
    weft.log(.info, msg);
}

/// Run the current file with its language's interpreter, output into *run*.
fn langRun() void {
    // Held across host calls (focusing *run*, starting the run): a read's
    // answer lives for the whole entry (`plugin_sdk/entry.zig`).
    const path = weft.path() orelse return;
    const l = langFor(path) orelse return;
    if (l.run.len == 0) return; // no runner for this language
    runSubst(l.run, path);
}

/// Run `template` — words, `{}` standing for the file — with `{}` replaced by
/// `path` as ONE argument, whatever the path contains: an argv, never a shell
/// line a path with a space or a quote would break. Its output streams into
/// `*run*`, its locations visitable.
fn runSubst(template: []const u8, path: []const u8) void {
    var words: weft.Argv = .{};
    var it = std.mem.tokenizeAny(u8, template, " \t");
    while (it.next()) |w| words.push(if (std.mem.eql(u8, w, "{}")) path else w);
    if (words.full or words.n == 0) return;
    output.show(words.slice(), "*run*", "modes-run", .{ .want_err = true });
}

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra, .init = initExtra }).exportAll();
}

comptime {
    weft.exportCallback("on_activate", &on_activate);
}
