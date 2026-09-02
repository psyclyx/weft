//! direnv — per-project environment tooling (design §6.6), a `.wasm` plugin
//! (perms `{proc, timer}`). It surfaces direnv's state/actions into tool
//! buffers via the native `proc` surface: status, allow (TOFU-shaped — runs
//! arbitrary code on the target host, hence a deliberate explicit action), and
//! reload. Applying the exported env to sibling `proc`/LSP calls (the
//! `direnv.env-for` provider) is the next step, once a per-project env overlay
//! crosses the membrane.
//!
//! No session/handle state here, unlike net/http/repl: every action is a
//! one-shot `proc.spawnHere` at the current locus, not a held connection, so
//! there's nothing to instance. The fixed `*direnv*` buffer is honest too — a
//! direnv environment is a property of ONE project root (`direnv.env-for`
//! will key by `(root, locus, .envrc hashToken)`, not by an arbitrary
//! instance count); this view shows the one direnv currently in view.

const std = @import("std");
const weft = @import("weft");

const cmds = [_]weft.CommandEntry{
    .{ .name = "direnv-status", .call = status, .summary = "say what direnv makes of this directory" },
    .{ .name = "direnv-allow", .call = allow, .summary = "allow this directory's .envrc" },
    .{ .name = "direnv-reload", .call = reload, .summary = "re-read the environment" },
    .{ .name = "direnv-apply", .call = apply, .summary = "apply this directory's environment" },
};

/// The fill token `direnv-apply` waits on. Any other fill in this buffer (a
/// `status`, an `allow`) must not be read as an environment.
const apply_token: u32 = 1;

fn describeExtra() void {
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
    // Publishing an environment for a place governs every subprocess ANY
    // plugin runs there, which is why this is its own capability and not
    // implied by `proc` — the same weight `direnv allow` already carries.
    weft.requestPerm(.env);
}

fn show(cmd: []const u8) void {
    weft.runStr("buffer-create", "*direnv*");
    weft.procToBuffer(cmd, "*direnv*", if (std.mem.startsWith(u8, cmd, "direnv exec")) apply_token else 0);
}
fn status() void {
    show("direnv status 2>&1");
}
fn allow() void {
    show("direnv allow 2>&1 && echo allowed");
}
fn reload() void {
    show("direnv reload 2>&1 && echo reloaded");
}

/// `direnv-apply` — hand this place the environment its `.envrc` describes, so
/// every child run here inherits it: a build, a language server, an agent.
///
/// `direnv exec . env` is used rather than `export json` because its output IS
/// the table's wire shape one substitution away (newline-separated rather than
/// NUL-separated), which keeps a JSON parser out of a freestanding guest. The
/// cost is honest and named: a value containing a newline cannot survive this
/// round trip, and is dropped rather than truncated.
fn apply() void {
    show("direnv exec . env 2>&1");
}

/// The environment landed in `*direnv*`. Read it back and publish it FOR THIS
/// PLACE — the host bound the entry this fill captured, so `envPublish` names
/// the place the command was run in, not wherever focus has since moved.
export fn on_fill_token(token: u32) void {
    if (token != apply_token) return;
    const total = weft.byteLen();
    if (total == 0) return weft.echo("direnv: nothing to apply here");

    // Sized to the environment, not to a guess about it. A fixed buffer here
    // would silently truncate a large one — and half an environment is worse
    // than none: the child gets some of the project's PATH and none of its
    // toolchain, then fails somewhere unrelated. A guest has a real growable
    // allocator (`weft.allocator`), so the limit has no reason to exist.
    const vars = weft.allocator.alloc(u8, total) catch
        return weft.echo("direnv: environment too large to apply");
    defer weft.allocator.free(vars);

    var w: usize = 0;
    var base: usize = 0;
    while (base < total) {
        const chunk = weft.slice(base, total);
        if (chunk.len == 0) break;
        for (chunk) |b| {
            // Chunk boundaries are safe to ignore: this is a byte-for-byte
            // copy with one substitution, so a record split across two reads
            // rejoins itself.
            vars[w] = if (b == '\n') 0 else b;
            w += 1;
        }
        base += chunk.len;
    }
    if (w == 0) return weft.echo("direnv: nothing to apply here");
    if (weft.envPublish(vars[0..w]) < 0) return weft.echo("direnv: could not apply");
    weft.echo("direnv: applied to this project");
}

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra }).exportAll();
}
