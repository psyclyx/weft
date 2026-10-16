//! console — command consoles (design §6.3, comint-flavored), a `.wasm` plugin
//! (perms `{proc, timer}`). `console.open` opens a console buffer; typing a
//! command and running `console.send` runs it (`sh -c`: what was typed IS a
//! shell line) and streams its output below as it is written (`weft.spawn`,
//! `weft.bufferAppend`). This is the STATELESS end of the REPL story — each
//! line is an independent command. A stateful REPL (python -i, nREPL, keeping
//! session state) is the `repl` plugin's persistent interactive-proc session.
//!
//! Consoles are INSTANCES: each open takes a fresh buffer (`*console*`,
//! `*console:2*`, …), so two of them keep separate logs. A send appends to the
//! focused console, else to the most recent one — echoing which.

const std = @import("std");
const weft = @import("weft");

/// Each open console, keyed by the log buffer it appends to; a console holds
/// no other state (each line is an independent command).
var consoles: weft.Instances(void) = .{};
var cmd_buf: [1 << 12]u8 = undefined;

/// One send's run: which log it appends to, and whether it has written yet
/// (its first output starts on a line of its own).
const Run = struct {
    log: [128]u8 = undefined,
    log_len: usize = 0,
    started: bool = false,

    fn name(self: *const Run) []const u8 {
        return self.log[0..self.log_len];
    }
};

/// The run's output, appended to its console's log as the command writes it.
const Output = struct {
    pub fn chunk(run: *Run, bytes: []const u8) void {
        if (!run.started) {
            run.started = true;
            weft.bufferAppend(run.name(), "\n", 0);
        }
        weft.bufferAppend(run.name(), bytes, 0);
    }

    pub fn exit(run: *Run, code: i32, stderr: []const u8) void {
        _ = code;
        _ = stderr;
        weft.allocator.destroy(run);
    }
};

/// `params` is the command's argument shape, written the way a person reads
/// it back (`describeCommand`): the palette shows it beside the row, the `:`
/// line hints it while you type, and it is what gets ASKED for when a call
/// arrives short.
const Cmd = struct {
    name: []const u8,
    handler: *const fn () void,
    params: []const u8 = "",
    summary: []const u8 = "",
};
const cmds = [_]weft.CommandEntry{
    .{ .name = "console.open", .call = open, .arity = .whole, .summary = "Open a new command console in its own buffer.", .label = "New Console", .menu = "Terminal", .group = "new", .order = 2, .icon = "terminal" },
    .{ .name = "console.send", .arity = .one, .call = send, .summary = "Run the current line in this console.", .label = "Send Line to Console" },
};

fn describeExtra() void {
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}

/// Open a console of its own.
fn open() void {
    const slot = consoles.open("console") orelse return weft.echo("console: out of memory — could not open another console");
    // `open` created and focused the console's buffer. It is a live resource
    // (doc/model.md §2.1) — `weft://here/proc/console`, `…/console.2` — that
    // designates something only while this plugin runs it.
    const bare = std.mem.trim(u8, slot.name(), "*");
    var id: [64]u8 = undefined;
    if (bare.len == 0 or bare.len > id.len) return;
    @memcpy(id[0..bare.len], bare);
    std.mem.replaceScalar(u8, id[0..bare.len], ':', '.');
    var named: [96]u8 = undefined;
    _ = weft.designate(std.fmt.bufPrint(&named, "weft://here/proc/{s}", .{id[0..bare.len]}) catch return);
}

/// Run the current line as a command; its output appends to that console.
fn send() void {
    const slot = consoles.current("console") orelse return; // resolve first: reading the line reuses the scratch
    const l = weft.lineAt(weft.cursor());
    const line = weft.slice(l.start, l.end);
    if (line.len == 0) return;
    const n = @min(line.len, cmd_buf.len);
    @memcpy(cmd_buf[0..n], line[0..n]); // copy — the read scratch is reused below
    const log = slot.name();
    const run = weft.allocator.create(Run) catch return;
    run.* = .{};
    run.log_len = @min(log.len, run.log.len);
    @memcpy(run.log[0..run.log_len], log[0..run.log_len]);
    // A typed line is a shell line by design: the shell is asked for, not
    // implied. Its stderr is part of what it said.
    if (weft.spawnWith(*Run, run, .{ .argv = &.{ "sh", "-c", cmd_buf[0..n] }, .merge_stderr = true }, Output) == null) {
        weft.allocator.destroy(run);
        weft.echo("console: the command could not be started");
    }
}

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra }).exportAll();
}
