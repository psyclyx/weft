//! modes — language activation (design §3/§6.2), a `.wasm` plugin. When a
//! buffer takes focus the host calls `on_activate`; modes reads the path,
//! detects the language by extension, and echoes it (a hook a richer mode set
//! layers language keymaps/facts onto). It also provides `lang-run`, a
//! self-adapting "run this file" that picks the interpreter by extension —
//! language awareness in the command, so it is always correct. perms
//! `{proc, timer}`.

const std = @import("std");
const weft = @import("weft");

var cmd_buf: [1 << 12]u8 = undefined;
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

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "lang-run", .handler = langRun },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// The host calls this when a buffer takes focus (design §3). BACKGROUND
/// (`on_activate` carries no per-call ctx at all — `wasm_host/commands.zig`'s
/// classification doc), so this can no longer `weft.echo` the detected
/// language directly: `wl_echo` is head-gated (task #19 item 4) and there is
/// no dispatching head to route through here (unlike `on_fill`/`on_poll`,
/// `on_activate` has no natural "the async thing that just landed" moment to
/// defer through a self-dispatched command either — it fires synchronously
/// off the SAME buffer-switch that would make the echo redundant a frame
/// later anyway). Downgraded to `weft.log` — still observable (the process
/// log), no longer a false promise of a user-visible echo this entry can't
/// honor. A per-head-aware activation echo is real future work, not solved
/// here (see `wasm_host/commands.zig`'s doc for the same "no ctx flows in"
/// limitation `on_menu` documents).
export fn on_activate() void {
    const path = weft.activatePath();
    const l = langFor(path) orelse return;
    const msg = std.fmt.bufPrint(&echo_buf, "mode: {s}", .{l.name}) catch return;
    weft.log(.info, msg);
}

/// Run the current file with its language's interpreter, output into *run*.
fn langRun() void {
    const path = weft.path() orelse return;
    const l = langFor(path) orelse return;
    if (l.run.len == 0) return; // no runner for this language
    runSubst(l.run, path);
}

/// Substitute `{}` → `path` in `template` into `cmd_buf` and run it.
fn runSubst(template: []const u8, path: []const u8) void {
    var w: usize = 0;
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '}') {
            const n = @min(path.len, cmd_buf.len - w);
            @memcpy(cmd_buf[w .. w + n], path[0..n]);
            w += n;
            i += 1;
        } else if (w < cmd_buf.len) {
            cmd_buf[w] = template[i];
            w += 1;
        }
    }
    weft.runStr("buffer-create", "*run*");
    weft.procToBuffer(cmd_buf[0..w], "*run*");
}
