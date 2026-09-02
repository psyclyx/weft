//! Commands: a guest registers one (cross-checked against its manifest) bound to
//! a trampoline that dispatches back into its on_command export; runs commands by
//! name (with int/str args); and introspects the registry (count/name/summary).
//!
//! HEAD ADDRESSING (doc/cwa-prior-docs-audit.md §5): a guest-backed
//! command dispatched "as" head B must see head B's interaction state (mode/
//! pending/pick/echo/dot-repeat), not whichever head happened to load the
//! plugin. Every `wasm_host/*` handler reaches state through `p.activeCtx()`
//! (`WasmPlugin.active_ctx`, doc there) instead of `p.ctx` directly; each
//! DISPATCHING host→guest entry sets it to the call's real ctx for the
//! call's duration (save/restore — reentrancy-safe, since a guest command can
//! `wl_run` another one). The SAME entries also set `p.in_dispatch = true`
//! for the call's duration (task #19 item 4, `WasmPlugin.in_dispatch`'s doc):
//! that classification is enumerated ONCE below and drives BOTH fields — a
//! DISPATCHING entry sets both `active_ctx` and `in_dispatch`; a BACKGROUND
//! one sets neither, leaving `activeCtx()` at the load-time default and
//! `wasm_host/plugin.zig`'s `requireDispatch` trapping any head-gated import
//! it reaches for. The classification, enumerating every host→guest entry
//! point in this plugin plane:
//!
//!   DISPATCHING (routes through the calling ctx — `activeCtx()` differs from
//!   the load-time `ctx` for the call's duration):
//!     - `on_command`      (`wpCmdTrampoline`, here) — a keymap/command-run
//!       dispatch; the ctx IS the dispatching head's.
//!     - `on_pick_accept`  (`pick.zig`'s `wpPickAccept`) — the ctx passed in
//!       is the head whose pick session just accepted.
//!
//!   BACKGROUND (always the load-time `ctx` — no per-call ctx flows in, or the
//!   call is explicitly system-scoped, frame-boundary work):
//!     - `init`/`describe` (`wasm_abi/runtime.zig`) — the load handshake;
//!       `active_ctx` still equals `ctx` at this point by construction.
//!     - `on_activate`     (`activation.zig`) — buffer-focus notification;
//!       no ctx parameter exists on this entry today (buffer activation is
//!       process-wide, not per-head, in the current single-rendered-head
//!       world — see `Session`'s module doc).
//!     - `on_poll`         (`activation.zig`) — async proc-stream readiness,
//!       fired at the frame boundary.
//!     - `on_fill_token`   (`proc.zig`) — post-delivery parse/paint for a
//!       `proc_to_buffer`/`proc_append_buffer` job, bound to the entry that
//!       job captured; fired off the async loop, not a keystroke.
//!     - `on_complete`     (`capability.zig`'s `wpCompletionProvider`) — the
//!       caps trampoline signature (`data, caps, req`) carries no ctx at all;
//!       a completion session isn't currently head-attributed upstream
//!       (`Context.fireRace`/`Caps.fire` don't carry one either) — a known
//!       limitation, not silently dropped: documented here so a future
//!       per-head completion pass knows where to plumb it through.
//!     - `on_menu`         (`menu.zig`'s `notifyMenu`) — fired at the frame
//!       boundary (never nested in a guest call, by its own doc), driven by
//!       "the" current head; no ctx parameter today, matching main()'s
//!       single-rendered-head reality (see `MenuOverlay`'s doc) — carries the
//!       same "no per-call ctx yet" shape as `on_activate`.
//!
//!   OUT OF SCOPE (not part of the resident-plugin plane this classification
//!   covers): `runGuest`'s one-shot `run` export (`wasm_abi/runtime.zig`) —
//!   the milestone-2 minimal-ABI proof, given exactly one ctx directly by its
//!   caller; there is no load-time/dispatch-time distinction to resolve.

const std = @import("std");
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const wasm_abi = @import("../wasm_abi.zig");
const WasmCmd = wasm_abi.WasmCmd;
const contract = @import("../membrane/contract.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

pub fn hRegister(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const cname = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    // Cross-check against the manifest: an undeclared command fails the load.
    // The declaration is also where the command's SHAPE comes from — a guest
    // that documented it (`describeCommand`) registers with the same summary
    // and `ArgSpec`s a core command carries, so the palette, the `:` line and
    // every refusal read it the same way. A bare declaration means both empty.
    const decl = p.declaration(cname) orelse {
        gpa.free(cname);
        p.load_error = error.UndeclaredCommand;
        results[0] = -1;
        return;
    };
    const wc = gpa.create(WasmCmd) catch {
        gpa.free(cname);
        results[0] = -1;
        return;
    };
    wc.* = .{ .plugin = p, .id = @intCast(p.commands.items.len), .name = cname };
    p.commands.append(gpa, wc) catch {
        gpa.free(cname);
        gpa.destroy(wc);
        results[0] = -1;
        return;
    };
    _ = p.activeCtx().commands.bind(gpa, wc.name, .{
        .name = wc.name,
        .summary = decl.summary,
        .args = decl.args,
        // Whose command this is. Borrowed from the plugin, which outlives
        // every command it registers.
        .owner = p.name,
        .handler = wpCmdTrampoline,
        .data = wc,
    }) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(wc.id);
}

/// A guest invoking a command is a person invoking a command: it is `:share`
/// typed on the ex line, or a palette row accepted. So every door here goes
/// through `command.invoke` — run AND report — rather than `run` with the
/// answer dropped. These four used to `catch {}` both the refusal and the
/// returned string, which is why `:share` answering "already shared" and
/// `:listen 7000` refusing on arity looked identical to a dead command.
fn invoke(p: *WasmPlugin, name: []const u8, args: []const command.Value) void {
    command.invoke(p.activeCtx().commands, p.activeCtx(), name, args);
}

pub fn hRun(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const cmd = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(cmd);
    invoke(p, cmd, &.{});
}

pub fn hRunInt(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const cmd = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(cmd);
    invoke(p, cmd, &.{.{ .integer = args[2] }});
}

pub fn hRunStr(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(cmd);
    const s = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(s);
    invoke(p, cmd, &.{.{ .string = s }});
}

pub fn hRunStr2(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(cmd);
    const a = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(a);
    const b = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer gpa.free(b);
    invoke(p, cmd, &.{ .{ .string = a }, .{ .string = b } });
}

/// The widest run door: `wl_run_argv(cmd, vec, argc)`, where `vec` points at
/// `argc` consecutive `(ptr, len)` u32 pairs in GUEST memory. `run_str`/
/// `run_str2` are the one- and two-argument shorthands a hand-written guest
/// reaches for; this is what a library invoking a command whose arity it only
/// learns at RUNTIME needs (`plugin_lib/invoke`), and it is why the invoker
/// has no arity ceiling baked into it.
pub fn hRunArgv(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(cmd);
    const argc: usize = @intCast(@max(args[3], 0));
    if (argc > max_argv) {
        // Refused OUT LOUD, on the same echo line every other refusal uses:
        // a guest that asked for a wider call has hit the gate above, and
        // silence here is the exact failure mode this whole change is about.
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}: too many arguments for a plugin to pass ({d} > {d})", .{
            cmd, argc, max_argv,
        }) catch "too many arguments";
        p.activeCtx().head.echo.clearRetainingCapacity();
        p.activeCtx().head.echo.appendSlice(gpa, msg) catch {};
        return;
    }
    // The vector first, as bytes, then each string it points at. An
    // out-of-bounds read refuses the WHOLE call (`readMemory` bounds-checks):
    // a partially decoded argument list would invoke the command with
    // something the guest did not say.
    const vec = caller.readMemory(gpa, @intCast(args[2]), argc * 8) catch return;
    defer gpa.free(vec);

    var values: [max_argv]command.Value = undefined;
    var owned: [max_argv][]u8 = undefined;
    var n: usize = 0;
    defer for (owned[0..n]) |s| gpa.free(s);
    while (n < argc) {
        const ptr = std.mem.readInt(u32, vec[n * 8 ..][0..4], .little);
        const len = std.mem.readInt(u32, vec[n * 8 + 4 ..][0..4], .little);
        const s = caller.readMemory(gpa, ptr, len) catch return;
        owned[n] = s;
        values[n] = .{ .string = s };
        n += 1;
    }
    invoke(p, cmd, values[0..argc]);
}

/// Arguments one `wl_run_argv` call may carry — and a SECURITY BOUND, not a
/// buffer size. `app/providers.zig`'s census gate turns on the fact that no
/// guest command runner passes three arguments: `grammar-add` needs three, and
/// what it does with them is `std.DynLib.open` on a caller-named directory.
/// Arity is the gate. A wider door here would open that one, which is why the
/// census lists this runner with the number below and the test fails if they
/// disagree. Read that gate before raising it.
const max_argv = 2;

// Introspection — command registry + open buffers.
pub fn hCommandCount(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(p.activeCtx().commands.count());
}

pub fn hCommandName(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const n: command.Commands.Name = @enumFromInt(@as(usize, @intCast(args[0])));
    if (p.activeCtx().commands.lookup(n) == null) {
        results[0] = -1;
        return;
    }
    const name = p.activeCtx().commands.nameOf(n);
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), name) catch 0);
}

pub fn hCommandSummary(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const n: command.Commands.Name = @enumFromInt(@as(usize, @intCast(args[0])));
    const cmd = p.activeCtx().commands.lookup(n) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), cmd.summary) catch 0);
}

/// `wl_command_owner(i, out, cap) -> i32`: WHO the `i`-th command belongs to.
///
/// A palette that wants to group by producer had exactly one way to guess
/// before this: parse the name. That is a convention nobody enforces, and it
/// is wrong for the cases grouping exists to fix — `motion.line-start` is
/// vim's, `zig` is `modes`', `pair-paren` is `autopair`'s, and none of them
/// say so. The registry knew all three at bind time.
///
/// A fact, not a policy: what to DO with a namespace is the asker's.
pub fn hCommandOwner(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const n: command.Commands.Name = @enumFromInt(@as(usize, @intCast(args[0])));
    const cmd = p.activeCtx().commands.lookup(n) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), cmd.owner) catch 0);
}

// ── A command's SHAPE, read back (the signature-help half) ───────────────
// A guest that means to invoke a command on a person's behalf has to know
// what the command takes — to split a typed line into the right arguments,
// to ask for the ones still missing, and to show the shape while they type.
// The registry already holds every command's declared `ArgSpec`s; these three
// doors are that fact, read. -1 throughout means "no such command/argument",
// never a guess.

pub fn hCommandArity(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const n: command.Commands.Name = @enumFromInt(@as(usize, @intCast(args[0])));
    const cmd = p.activeCtx().commands.lookup(n) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(cmd.args.len);
}

/// How many of them a caller MUST supply — optional arguments trail, so a
/// guest filling left to right knows exactly where it may stop asking.
pub fn hCommandArityRequired(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const n: command.Commands.Name = @enumFromInt(@as(usize, @intCast(args[0])));
    const cmd = p.activeCtx().commands.lookup(n) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(command.requiredArity(cmd.args));
}

/// The `k`-th argument's NAME (`port`, `access`, `preset`) into guest memory —
/// what a prompt labels itself with and what a signature hint shows.
pub fn hCommandArg(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const n: command.Commands.Name = @enumFromInt(@as(usize, @intCast(args[0])));
    const cmd = p.activeCtx().commands.lookup(n) orelse {
        results[0] = -1;
        return;
    };
    const k: usize = @intCast(@max(args[1], 0));
    if (k >= cmd.args.len) {
        results[0] = -1;
        return;
    }
    results[0] = @intCast(caller.writeMemory(@intCast(args[2]), @intCast(args[3]), cmd.args[k].name) catch 0);
}

/// Command dispatch back into the guest: stash the args (readable via
/// `wl_arg_*`), reset the result, run `on_command(id)`, and return whatever
/// result the guest set (`wl_set_result_*`, default nil). String results
/// borrow the plugin's `result_buf` until the next dispatch.
///
/// THE FIX (module doc): `ctx` here is the DISPATCHING head's ctx — the one
/// `command.run` was actually invoked with, not necessarily the plugin's
/// load-time one. Route `p.active_ctx` through it for the call's duration
/// (save/restore, not a bare set — `on_command` can itself `wl_run` another
/// command, on this plugin or another, so this must nest correctly) so every
/// `wasm_host/*` handler this guest call reaches (via `activeCtx()`) sees the
/// dispatching head's mode/pending/pick/echo/dot-repeat, not whichever head's
/// `Head` the plugin happened to be loaded against.
fn wpCmdTrampoline(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
    const wc: *WasmCmd = @ptrCast(@alignCast(data.?));
    const p = wc.plugin;
    const top_level = p.dispatch_depth == 0;
    if (top_level) {
        p.clearEphemeralRanges();
        p.clearRetiredResultBuffers();
    } else {
        // Reserve before entering the guest so moving this call's result
        // backing into retirement during unwind is infallible.
        try p.retired_result_bufs.ensureUnusedCapacity(p.gpa, 1);
    }
    const saved_ctx = p.active_ctx;
    const saved_dispatch = p.in_dispatch;
    const saved_args = p.cur_args;
    const saved_result = p.result;
    var saved_result_buf: std.ArrayList(u8) = .empty;
    if (!top_level) {
        saved_result_buf = p.result_buf;
        p.result_buf = .empty;
    }
    p.dispatch_depth += 1;
    p.active_ctx = ctx;
    // DISPATCHING (task #19 item 4, alongside `active_ctx` above): this entry
    // is `on_command` — head-gated imports (`wl_set_mode`, `wl_echo`, …) may
    // fire for the call's duration, regardless of whether a real keystroke or
    // a nested `wl_run` (even one issued from a BACKGROUND entry) got us
    // here — see `wasm_host/plugin.zig`'s `requireDispatch` doc for why that
    // nested-from-background case is a sanctioned door, not a bug.
    p.in_dispatch = true;
    defer {
        p.dispatch_depth -= 1;
        p.active_ctx = saved_ctx;
        p.in_dispatch = saved_dispatch;
        p.cur_args = saved_args;
        p.result = saved_result;
        if (!top_level) {
            const completed_result_buf = p.result_buf;
            p.result_buf = saved_result_buf;
            p.retired_result_bufs.appendAssumeCapacity(completed_result_buf);
        }
    }
    p.cur_args = args;
    p.result = .nil;
    try contract.callRequiredExport("on_command", &p.instance, .{@as(i32, @intCast(wc.id))});
    return p.result;
}
