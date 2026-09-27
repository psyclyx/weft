//! make — build/test runners into tool buffers, a `.wasm` plugin. Each command
//! creates+focuses a tool buffer and fills it asynchronously with the output of
//! a build invocation via the native `proc` surface — the output lands authored
//! as this plugin's peer, off the frame thread. perms `{proc, timer}`; it only
//! writes its own tool buffers. Commands are hardcoded for now; project-aware
//! detection (which runner, which target) arrives with the project plugin.
//! Build output is navigable exactly like `run`'s because both consume
//! `output.zig` — same table, same visit — not because `make` borrows `run`'s
//! mode: it owns `build`, and works whether or not `run` is loaded.

const std = @import("std");
const weft = @import("weft");
const output = @import("weft_output");
const statusline = @import("weft_statusline");

const cmds = [_]weft.CommandEntry{
    .{ .name = "make.build", .arity = .whole, .call = makeBuild, .summary = "Build this project.", .label = "Build Project", .menu = "Run", .group = "make", .order = 1, .icon = "build" },
    .{ .name = "make.test", .arity = .whole, .call = makeTest, .summary = "Run this project's tests.", .label = "Run Tests", .menu = "Run", .group = "make", .order = 2, .icon = "test" },
    .{ .name = "make.run", .arity = .whole, .call = makeRun, .summary = "Run this project.", .label = "Run Project", .menu = "Run", .group = "make", .order = 3, .icon = "play" },
    .{ .name = "make.visit", .arity = .one, .call = output.visit, .summary = "Open the location the focused build row names.", .internal = true },
    .{ .name = "make.open", .arity = .whole, .call = reopen, .params = "designation", .summary = "Run the build a `weft://here/make/…` designation names.", .internal = true },
};

fn describeExtra() void {
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
fn initExtra() void {
    // Return jumps to the compiler error the focused row points at.
    output.installMode("build", "make.visit");
    // A running build on the status line, after the problems counts (95).
    statusline.bind(.{ .all = &.{} }, .core, 94);
    // A build is a projection this plugin re-runs by designation.
    _ = weft.designationOpener(kind, "make.open");
}

/// The projection kind a build is (doc/model.md §2.1):
/// `weft://here/make/<place>?run=build|test|make`.
const kind = "make";

// A build says what went wrong on STDERR, which is the whole reason to have a
// navigable build buffer — and which the stdout-only fill door dropped on the
// floor. `want_err` is what makes `make.build` on a broken tree show the
// errors rather than an empty window.
fn makeBuild() void {
    output.show(&.{ "zig", "build" }, "*build*", "build", .{ .want_err = true, .running = .{ .key = running_key, .what = "build" } });
    output.designate(kind, "run=build");
}
fn makeTest() void {
    output.show(&.{ "zig", "build", "test" }, "*test*", "build", .{ .want_err = true, .running = .{ .key = running_key, .what = "test" } });
    output.designate(kind, "run=test");
}
fn makeRun() void {
    output.show(&.{"make"}, "*build*", "build", .{ .want_err = true, .running = .{ .key = running_key, .what = "make" } });
    output.designate(kind, "run=make");
}

/// The opener for `weft://here/make/<place>?run=…`: that run again, here.
fn reopen() void {
    const d = output.reopening(kind) orelse return;
    const run = d.param("run") orelse "build";
    if (std.mem.eql(u8, run, "test")) return makeTest();
    if (std.mem.eql(u8, run, "make")) return makeRun();
    makeBuild();
}

// ── A running build, on the status line (doc/chrome.md §4.3) ────────────────

/// Said on the place a build started in while it runs (`output.Running`).
const running_key = "make.running";

fn onSlotFire(session: i32) callconv(.c) void {
    const handle: u32 = @bitCast(session);
    _ = statusline.ask(handle) orelse return;
    const what = output.runningHere(running_key) orelse return statusline.tell(handle, &.{});
    var buf: [48]u8 = undefined;
    statusline.tell(handle, &.{.{
        .text = std.fmt.bufPrint(&buf, "{s}…", .{what}) catch what,
        .role = .accent,
        .priority = 55,
        .icon = "hammer",
        .tooltip = "Running",
    }});
}

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra, .init = initExtra }).exportAll();
    weft.exportCallback("on_slot_fire", &onSlotFire);
}
