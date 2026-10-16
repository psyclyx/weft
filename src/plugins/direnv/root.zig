//! direnv — per-project environment tooling (design §6.6), a `.wasm` plugin
//! (perms `{proc, timer}`). It surfaces direnv's state/actions into tool
//! buffers, streamed as direnv writes them: status, allow (TOFU-shaped — runs
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
const output = @import("weft_output");

const cmds = [_]weft.CommandEntry{
    .{ .name = "direnv.status", .arity = .whole, .call = status, .summary = "Say what direnv makes of this directory.", .label = "Show Direnv Status", .menu = "Terminal/Direnv", .group = "direnv", .order = 1 },
    .{ .name = "direnv.allow", .arity = .whole, .call = allow, .summary = "Allow this directory's .envrc.", .label = "Allow Direnv", .menu = "Terminal/Direnv", .group = "direnv", .order = 2, .icon = "shield-check" },
    .{ .name = "direnv.reload", .arity = .whole, .call = reload, .summary = "Re-read the environment direnv provides.", .label = "Reload Direnv Environment", .menu = "Terminal/Direnv", .group = "direnv", .order = 3, .icon = "refresh" },
    .{ .name = "direnv.apply", .arity = .whole, .call = apply, .summary = "Apply this directory's environment.", .label = "Apply Direnv Environment", .menu = "Terminal/Direnv", .group = "direnv", .order = 4 },
    .{ .name = "direnv.visit", .call = output.visit, .arity = .one, .summary = "Open the location the focused row names.", .internal = true },
};

fn initExtra() void {
    output.installMode("direnv", "direnv.visit");
}

fn describeExtra() void {
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
    // Publishing an environment for a place governs every subprocess ANY
    // plugin runs there, which is why this is its own capability and not
    // implied by `proc` — the same weight `direnv allow` already carries.
    weft.requestPerm(.env);
}

/// Run `argv` (direnv itself — no shell) into `*direnv*`, its messages and
/// errors as they come.
fn show(argv: []const []const u8, done: ?*const fn (code: i32) void) void {
    output.show(argv, "*direnv*", "direnv", .{ .want_err = true, .exit = done });
}

fn status() void {
    show(&.{ "direnv", "status" }, null);
}

fn allow() void {
    show(&.{ "direnv", "allow" }, said("allowed"));
}

fn reload() void {
    show(&.{ "direnv", "reload" }, said("reloaded"));
}

/// direnv says nothing when it succeeds: say it for it.
fn said(comptime word: []const u8) *const fn (code: i32) void {
    return struct {
        fn f(code: i32) void {
            weft.echo(if (code == 0) "direnv: " ++ word else "direnv: failed — see *direnv*");
        }
    }.f;
}

/// `direnv.apply` — hand this place the environment its `.envrc` describes, so
/// every child run here inherits it: a build, a language server, an agent.
///
/// `direnv exec . env` is used rather than `export json` because its output IS
/// the table's wire shape one substitution away (newline-separated rather than
/// NUL-separated), which keeps a JSON parser out of a freestanding guest. The
/// cost is honest and named: a value containing a newline cannot survive this
/// round trip, and is dropped rather than truncated.
fn apply() void {
    if (!weft.exec(.{ .argv = &.{ "direnv", "exec", ".", "env" } }, applied))
        weft.echo("direnv: could not run direnv");
}

/// The environment, published FOR THIS PLACE: an exec continuation runs in
/// the place its command was issued in, not wherever focus has moved since.
fn applied(r: weft.ExecDone) void {
    if (!r.ok()) {
        var err: [256]u8 = undefined;
        const why = r.firstLine(.err, &err);
        return weft.echo(if (why.len > 0) why else "direnv: could not read this directory's environment");
    }
    // Sized to the environment, not to a guess about it: half an environment
    // is worse than none.
    const vars = r.dupe(weft.allocator, .out) catch
        return weft.echo("direnv: environment too large to apply");
    defer weft.allocator.free(vars);
    if (vars.len == 0) return weft.echo("direnv: nothing to apply here");
    std.mem.replaceScalar(u8, vars, '\n', 0);
    if (weft.envPublish(vars) < 0) return weft.echo("direnv: could not apply");
    weft.echo("direnv: applied to this project");
}

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra, .init = initExtra }).exportAll();
}
