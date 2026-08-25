//! Test fixture ONLY (not installed — see build.zig's `guests` table): a
//! minimal guest exercising the guest-ABI head-addressing fix (task #14,
//! doc/north-star-plan.md §2.1/§2.7) AND its structural closure (task #19
//! item 4). Six commands plus an `on_poll` export, sized exactly for what
//! `src/e2e/two_head_test.zig` needs to prove:
//!
//!   - `head-poke`: `weft.setMode`/`weft.echo` — the two host-import writes
//!     that read/mutate `p.activeCtx().head` (mode + echo line). Dispatched
//!     "as" a given `core.Head` (via `command.run`'s `ctx`), this must land
//!     on THAT head, not whichever head loaded the plugin.
//!   - `head-relay`: `weft.run("head-poke")` (a synchronous, in-guest
//!     reentrant dispatch — `wl_run`) THEN another `weft.echo` AFTER the
//!     nested call returns — proving `active_ctx`/`in_dispatch` are saved/
//!     restored around the nested dispatch (still the SAME dispatching head
//!     before and after), not merely set-and-forgotten-at-load or reset to
//!     the load-time default the instant the inner call returns.
//!   - `head-range-source` / `head-range-relay`: the relay creates its own
//!     live range, synchronously asks this SAME plugin for another range, then
//!     returns the original. This proves nested dispatch cannot clear its
//!     caller's document anchors or overwrite its result state.
//!   - `head-spawn`: `weft.procSpawn` (perm proc only) — spawns a real
//!     subprocess so the host's readiness-driven `on_poll` (BACKGROUND,
//!     wasm_host/commands.zig's classification) fires for real off the
//!     frame-loop tick, not a synthetic direct export call.
//!   - `head-poll-count`: returns how many times `on_poll` has fired (a
//!     command result, not head state) — the OBSERVABLE proof that a real
//!     `on_poll` ran even though (per the next bullet) its `setMode`/`echo`
//!     writes no longer take effect, so a test can't infer "did on_poll run
//!     at all" from a head mutation that's now structurally blocked.
//!   - `on_poll`: attempts the SAME `setMode`/`echo` writes as `head-poke`,
//!     from a BACKGROUND entry. Before task #19 item 4 these silently
//!     landed on the load-time (system default) ctx regardless of which
//!     head last dispatched — the gap `wasm_host/commands.zig`'s doc named
//!     but didn't close. NOW: `wl_set_mode` traps (`requireDispatch`,
//!     `wasm_host/plugin.zig`) before mutating anything, so `weft.echo`
//!     right after it never even runs (a trap unwinds the whole guest
//!     call). Kept as `poked`/`polled` naming so a diff against the
//!     pre-item-4 fixture reads as "same shape, now denied," not rewritten.

const weft = @import("weft");

var poll_count: i32 = 0;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "head-poke", .handler = poke },
    .{ .name = "head-relay", .handler = relay },
    .{ .name = "head-spawn", .handler = spawn },
    .{ .name = "head-poll-count", .handler = pollCount },
    .{ .name = "head-range-source", .handler = rangeSource },
    .{ .name = "head-range-relay", .handler = rangeRelay },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.proc);
}

export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
    // task #19 item 4: a TABLE-CONFIG declaration (system-scoped — Keymap
    // owns it, not Head — contract_data.zig's `.head_gated` doc), legal from
    // `init` (a BACKGROUND entry) precisely BECAUSE it isn't head state. If
    // `wl_resting_mode` were ever (mis-)classified head-gated, EVERY guest
    // load in the test suite would start trapping right here — this call is
    // the direct, minimal proof it isn't.
    weft.restingMode("poked");
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

fn rangeSource() void {
    const h = weft.anchorRange(.{ .start = 0, .end = @min(1, weft.byteLen()) }) orelse return;
    weft.setResultRange(h);
}

fn rangeRelay() void {
    const len = weft.byteLen();
    const outer = weft.anchorRange(.{ .start = @min(1, len), .end = @min(2, len) }) orelse return;
    const inner = weft.runRange("head-range-source") orelse return;
    const inner_ends = weft.rangeEnds(inner) orelse return;
    if (inner_ends.start != 0 or inner_ends.end != @min(1, len)) return;
    weft.setResultRange(outer);
}

/// Fire-and-forget: spawn a real subprocess so `on_poll` fires for real once
/// its stdout has bytes pending (readiness-driven — see `wasm_host/
/// activation.zig`'s `notifyPollIfReady`).
fn spawn() void {
    _ = weft.procSpawn("echo hi");
}

/// How many times `on_poll` has fired — read this (via `command.run`, a
/// DISPATCHING call) instead of inferring "did on_poll run" from a head
/// mutation, since `on_poll`'s own head-touching writes are now blocked.
fn pollCount() void {
    weft.setResultInt(poll_count);
}

/// BACKGROUND (task #19 item 4's proof): `wl_set_mode` traps here —
/// `requireDispatch` denies a head-gated import outside a dispatching entry
/// — so `weft.echo` right after it is UNREACHED (the trap unwinds this
/// whole call). `poll_count` increments FIRST, so it still counts a real
/// on_poll firing even though everything after the trap point is dead code
/// from here on.
export fn on_poll() void {
    poll_count += 1;
    weft.setMode("polled");
    weft.echo("polled");
}
