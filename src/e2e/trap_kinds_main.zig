//! Standalone e2e executable (`zig build e2e-trap-kinds`) — task #8's
//! deny-vs-crash channel split, proven by actually letting BOTH sides fire.
//!
//! This is deliberately NOT a `test` block. `zig build test` runs on Zig
//! 0.16's default test runner (`lib/zig/compiler/test_runner.zig`), which
//! fails the WHOLE suite the instant ANY test logs at `.err`
//! (`log_err_count`); this repo has no custom test runner / per-test
//! downgrade shim to opt a single test out of that gate. A genuine guest
//! crash logging `.err` is exactly the property task #8 restores
//! (`wasm.zig`'s `checkTrap`) — proving it FIRES requires a build step that
//! is allowed to see an `.err` log without failing. Hence: a plain
//! executable with its own `logFn`, wired as its own `zig build` step
//! (mirroring `e2e-latency`/`e2e-popup-layout`'s "dedicated step outside
//! `test`" doctrine, adapted to `addExecutable` since `addTest`'s harness
//! IS the thing being worked around here).
//!
//! Two scenarios, proving the channel split `wasm.zig`'s module doc
//! describes: a NATIVE guest fault (`unreachable`, no host callback in the
//! loop at all) must log `.err`; a HOST-raised deny (`Caller.trap`, from a
//! host import callback) must log `.warn` and must NOT log `.err`. Both are
//! asserted directly against captured log records — not eyeballed.

const std = @import("std");
const weft = @import("weft");
const wasm = weft.core.wasm;

pub const std_options: std.Options = .{ .logFn = capture };

var last_level: ?std.log.Level = null;
var last_msg_buf: [256]u8 = undefined;
var last_msg: []const u8 = "";
var saw_err_this_scenario = false;

fn capture(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    last_level = level;
    last_msg = std.fmt.bufPrint(&last_msg_buf, format, args) catch "<message too long to capture>";
    if (level == .err) saw_err_this_scenario = true;
    // Still visible on the terminal — this is a diagnostic tool, not a
    // silent harness; a human re-running it should see exactly what fired.
    std.debug.print("[{s}:{t}] {s}\n", .{ @tagName(scope), level, last_msg });
}

// A guest exporting `boom() -> ()` whose body is the single instruction
// `unreachable` — no import, no host callback in the loop at all. This is
// the shape a REAL guest crash takes (unreachable / an out-of-bounds
// access / ...), never something `Caller.trap()` produces.
const boom_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // \0asm, version 1
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: ()->()
    0x03, 0x02, 0x01, 0x00, // func: one, type 0
    0x07, 0x08, 0x01, 0x04, 0x62, 0x6f, 0x6f, 0x6d, 0x00, 0x00, // export "boom" = func 0
    0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b, // code: locals=0, unreachable, end
};

// A guest importing `env.deny: () -> ()` and exporting `run() -> ()` which
// calls it once — the deny shape: a host import callback raises the trap
// via `Caller.trap()`, never the guest's own bytecode faulting.
const deny_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // \0asm, version 1
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: ()->()
    0x02, 0x0c, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x04, 0x64, 0x65, 0x6e, 0x79, 0x00, 0x00, // import "env" "deny" type0
    0x03, 0x02, 0x01, 0x00, // func "run" type0 (func index 1; import is 0)
    0x07, 0x07, 0x01, 0x03, 0x72, 0x75, 0x6e, 0x00, 0x01, // export "run" = func 1
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x10, 0x00, 0x0b, // code: call 0 (the import); end
};

fn denyCallback(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = data;
    _ = args;
    _ = results;
    caller.trap("e2e-trap-kinds: deliberate deny", .{});
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    var ok = true;

    // Scenario 1: a genuine guest crash — must log .err (task #8's core ask:
    // this is the observability the W0a-B review traded away, restored).
    {
        saw_err_this_scenario = false;
        last_level = null;
        var engine = try wasm.Engine.init();
        defer engine.deinit();
        var module = try engine.compile(&boom_wasm);
        defer module.deinit();
        var instance = try wasm.Instance.init(&engine, &module);
        defer instance.deinit();

        const result = instance.callVoid("boom", &.{});
        if (result != error.Trap) {
            std.debug.print("FAIL: boom() should have trapped, got {any}\n", .{result});
            ok = false;
        }
        if (!saw_err_this_scenario) {
            std.debug.print("FAIL: a native guest fault (unreachable) must log .err — it didn't (last level: {?})\n", .{last_level});
            ok = false;
        } else {
            std.debug.print("OK: native guest fault (unreachable) logged .err, as task #8 requires\n", .{});
        }
    }

    // Scenario 2: a host-raised deny — must stay .warn, must NEVER log .err
    // (the exact thing that would re-alarm on an ordinary protocol denial).
    {
        saw_err_this_scenario = false;
        last_level = null;
        var engine = try wasm.Engine.init();
        defer engine.deinit();
        var module = try engine.compile(&deny_wasm);
        defer module.deinit();
        var linker = try wasm.Linker.init(&engine);
        defer linker.deinit();
        try linker.defineFn("env", "deny", 0, 0, denyCallback, null);
        var instance = try linker.instantiate(&module);
        defer instance.deinit();

        const result = instance.callVoid("run", &.{});
        if (result != error.Trap) {
            std.debug.print("FAIL: run() should have trapped, got {any}\n", .{result});
            ok = false;
        }
        if (saw_err_this_scenario) {
            std.debug.print("FAIL: a host-raised deny must NEVER log .err (it did) — deny paths must not re-alarm like a crash\n", .{});
            ok = false;
        }
        if (last_level != .warn) {
            std.debug.print("FAIL: a host-raised deny must log .warn, last level was {?}\n", .{last_level});
            ok = false;
        } else {
            std.debug.print("OK: host-raised deny logged .warn (not .err), as task #8 requires\n", .{});
        }
    }

    if (!ok) {
        std.debug.print("e2e-trap-kinds: FAILED\n", .{});
        std.process.exit(1);
    }
    std.debug.print("e2e-trap-kinds: the deny/crash channel split holds\n", .{});
}
