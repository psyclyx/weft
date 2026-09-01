//! The `env` capability: publishing an environment overlay for a place.
//!
//! `env.zig` is the table; this is the door onto it. Both doors act on the
//! DISPATCHING place and on the calling plugin's own name — a guest cannot name
//! a place it is not in, and cannot withdraw an overlay it did not publish.
//! That is the same ambient-read-at-the-door shape the spawn sites use, for the
//! same reason: nothing is passed, so nothing can be passed wrong.
//!
//! Gated on `env`, NOT on `proc`. Spawning a child affects only your own
//! children; setting `PATH` for a place owns every subprocess any plugin runs
//! there, which is an escalation `proc` does not imply. `direnv` already treats
//! its own `allow` as TOFU-shaped — "runs arbitrary code on the target host,
//! hence a deliberate explicit action" — and an overlay inherits exactly that
//! weight.

const std = @import("std");
const wasm = @import("../wasm.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const requirePerm = shared.requirePerm;

/// `envPublish(vars) -> revision` (perm env, trap on deny), or -1 when there is
/// no table to publish into.
///
/// `vars` is NUL-separated `KEY=VALUE` records — the publisher's own wire
/// shape, which the table stores without interpreting. A record with no `=`, or
/// an empty name, is dropped at resolution rather than read as "set this to
/// empty", so a malformed publish cannot blank an inherited key.
pub fn hEnvPublish(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!requirePerm(p, caller, .env)) return;
    const ctx = p.activeCtx();
    const envs = ctx.environments orelse {
        results[0] = -1;
        return;
    };
    const vars = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(vars);
    const revision = envs.publish(ctx.place(), p.name, vars) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(@min(revision, @as(u64, std.math.maxInt(i32))));
}
