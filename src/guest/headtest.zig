//! Test fixture ONLY (not installed — see build.zig's `guests` table): a
//! minimal guest exercising the guest-ABI head-addressing fix (task #14,
//! doc/north-star-plan.md §2.1/§2.7; the gap this closes was reported, not
//! patched, in `src/e2e/two_head_test.zig`'s original header). Three
//! commands plus an `on_poll` export, sized exactly for what that test file
//! needs to prove:
//!
//!   - `head-poke`: `weft.setMode`/`weft.echo` — the two host-import writes
//!     that read/mutate `p.activeCtx().head` (mode + echo line). Dispatched
//!     "as" a given `core.Head` (via `command.run`'s `ctx`), this must land
//!     on THAT head, not whichever head loaded the plugin.
//!   - `head-relay`: `weft.run("head-poke")` (a synchronous, in-guest
//!     reentrant dispatch — `wl_run`) THEN another `weft.echo` AFTER the
//!     nested call returns — proving `active_ctx` is saved/restored around
//!     the nested dispatch (still the SAME dispatching head before and
//!     after), not merely set-and-forgotten-at-load or reset to the load-
//!     time default the instant the inner call returns.
//!   - `head-spawn`: `weft.procSpawn` (perm proc only) — spawns a real
//!     subprocess so the host's readiness-driven `on_poll` (BACKGROUND,
//!     wasm_host/commands.zig's classification) fires for real off the
//!     frame-loop tick, not a synthetic direct export call.
//!   - `on_poll`: the same `setMode`/`echo` writes as `head-poke`, but from
//!     a BACKGROUND entry — must target the load-time (system default) ctx
//!     regardless of which head last dispatched a command.

const weft = @import("weft.zig");

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "head-poke", .handler = poke },
    .{ .name = "head-relay", .handler = relay },
    .{ .name = "head-spawn", .handler = spawn },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.proc);
}

export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}

export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

fn poke() void {
    weft.setMode("poked");
    weft.echo("poked");
}

/// Nested dispatch (`wl_run`) through the SAME plugin: `head-poke` runs to
/// completion (mode → "poked", echo → "poked"), THEN this handler keeps
/// running and overwrites the echo again — the assertion the reentrancy
/// test hinges on is that THIS second write still lands on the dispatching
/// head, not the plugin's load-time one.
fn relay() void {
    weft.run("head-poke");
    weft.echo("after-relay");
}

/// Fire-and-forget: spawn a real subprocess so `on_poll` fires for real once
/// its stdout has bytes pending (readiness-driven — see `wasm_host/
/// activation.zig`'s `notifyPollIfReady`).
fn spawn() void {
    _ = weft.procSpawn("echo hi");
}

export fn on_poll() void {
    weft.setMode("polled");
    weft.echo("polled");
}
