//! exec_gate (wasm) — the gate guest for `wl_exec`.
//!
//! It holds `{proc, timer}` and nothing else, like `spool`, because `exec`
//! grants nothing the fill doors did not. What it proves is the three facts the
//! fill doors could not carry:
//!
//!   - the EXIT STATUS crosses as a number, not as a sentinel the command
//!     prints into its own stdout for the plugin to scan back out;
//!   - stderr arrives SEPARATELY, not folded into stdout with `2>&1`;
//!   - an argument is one argument. `exec-argv` passes a string full of the
//!     characters a shell would act on — spaces, a quote, a `;`, a `$` — and
//!     the child sees it whole. There is no quoting layer to get wrong because
//!     there is no shell.
//!
//! …and that the spool contract survives the move to argv: `exec-spool` hands
//! the child bytes as a real file through a bare `{}` argument, with no `fs`
//! permission anywhere in this guest.
//!
//! Each command records what it learned into a buffer the host-side test reads,
//! because a wasm guest has no other way to report. The RESULT itself never
//! goes through a buffer — that is the point.

const std = @import("std");
const weft = @import("weft");

const cmds = [_]weft.CommandEntry{
    .{ .name = "exec-ok", .call = execOk },
    .{ .name = "exec-fail", .call = execFail },
    .{ .name = "exec-argv", .call = execArgv },
    .{ .name = "exec-spool", .call = execSpool },
    .{ .name = "exec-ctx", .call = execCtx },
};
comptime {
    weft.plugin(&cmds, .{ .perms = &.{ .proc, .timer } }).exportAll();
}

var report: [4096]u8 = undefined;

/// Write what the delivery said into a buffer of its own, which is the only
/// channel a guest has back to the host-side gate. One buffer PER command:
/// `buffer-create` does not dedupe by name, so a shared report entry would be
/// a fresh empty buffer each time and the gate would read the first one.
fn note(name: []const u8, comptime fmt: []const u8, args: anytype) void {
    const line = std.fmt.bufPrint(&report, fmt, args) catch return;
    weft.runStr("buffer-create", name);
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, line);
}

/// A clean exit, with something on each stream. The two must arrive apart.
fn execOk() void {
    _ = weft.exec(.{
        .argv = &.{ "/bin/sh", "-c", "printf out-said; printf err-said >&2" },
    }, struct {
        fn done(r: weft.ExecDone) void {
            var out: [128]u8 = undefined;
            var err: [128]u8 = undefined;
            note("*exec-ok*", "status={d} out={s} err={s}", .{
                r.status,
                r.read(.out, 0, &out),
                r.read(.err, 0, &err),
            });
        }
    }.done);
}

/// A NON-ZERO exit. The number crosses on its own; nothing in stdout says it.
fn execFail() void {
    _ = weft.exec(.{
        .argv = &.{ "/bin/sh", "-c", "printf nope >&2; exit 7" },
    }, struct {
        fn done(r: weft.ExecDone) void {
            var err: [128]u8 = undefined;
            note("*exec-fail*", "status={d} ok={} err={s}", .{ r.status, r.ok(), r.read(.err, 0, &err) });
        }
    }.done);
}

/// ONE argument, containing every character a shell would have acted on. It
/// arrives whole: `printf %s` writes exactly what was passed.
const hostile_arg = "a b; rm -rf $HOME 'quoted' \"double\" `sub` | pipe";

fn execArgv() void {
    _ = weft.exec(.{
        .argv = &.{ "/bin/sh", "-c", "printf %s \"$1\"", "sh", hostile_arg },
    }, struct {
        fn done(r: weft.ExecDone) void {
            var out: [256]u8 = undefined;
            const got = r.read(.out, 0, &out);
            note("*exec-argv*", "whole={} got={s}", .{ std.mem.eql(u8, got, hostile_arg), got });
        }
    }.done);
}

/// The spool contract, argv-shaped: a bare `{}` ARGUMENT becomes a temp the
/// host names, fills, and deletes. The guest holds no `fs` permission at all.
fn execSpool() void {
    _ = weft.exec(.{
        .argv = &.{ "/bin/sh", "-c", "read -r l < \"$1\"; printf 'in=%s at=%s' \"$l\" \"$1\"", "sh", "{}" },
        .input = "hello exec\n",
    }, struct {
        fn done(r: weft.ExecDone) void {
            var out: [256]u8 = undefined;
            note("*exec-spool*", "{s}", .{r.read(.out, 0, &out)});
        }
    }.done);
}

/// A continuation carrying a value of its own — the thing that used to be
/// packed into a token and unpacked in a demux.
fn execCtx() void {
    _ = weft.execWith(u32, 4242, .{
        .argv = &.{ "/bin/sh", "-c", "printf ran" },
    }, struct {
        fn done(r: weft.ExecDone, carried: u32) void {
            var out: [64]u8 = undefined;
            note("*exec-ctx*", "carried={d} out={s}", .{ carried, r.read(.out, 0, &out) });
        }
    }.done);
}
