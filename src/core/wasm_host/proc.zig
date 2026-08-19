//! Perm-gated off-thread process effects (proc + timer): shell-insert at the
//! cursor, proc-to/append-buffer (tool output → a scratch buffer), and the
//! in-place range filter (formatters). Each schedules on the async loop and
//! lands its result on the frame thread, rebased + authored as the plugin peer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const Buffers = @import("../Buffers.zig");
const proc = @import("../proc.zig");
const authority = @import("../authority.zig");
const position = @import("../position.zig");
const file = @import("../file.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const perm_proc = shared.perm_proc;
const perm_timer = shared.perm_timer;

/// A deferred shell insert, owned across the frame→pool→frame hop. Holds no
/// plugin pointer — it re-resolves the doc + peer by name at delivery, so it
/// survives the plugin being unloaded mid-flight (mirrors abi.zig's
/// DeferredEdit). Freed in every terminal case by the sink's deinit.
const ShellJob = struct {
    ctx: *command.Context,
    name: []u8,
    version: []u8, // the version `offset` is stamped against
    offset: usize,
    cmd: []u8, // the shell command line
};

/// Perm-gated (proc + timer): run `<cmd>` off the frame thread and insert its
/// stdout at the cursor when it finishes — rebased if the buffer moved,
/// authored as this plugin's peer. The membrane form of shell.zig's
/// `editLater(runCmd, cmd)`: same async + rebase + authority, but the proc
/// body runs host-side (the design's "route proc through the host import").
pub fn hShellInsert(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    // The perm model: dropped (no ghost) unless the plugin declared proc+timer.
    if (!p.perms[perm_proc] or !p.perms[perm_timer]) return;
    const loop = p.loop orelse return;
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    errdefer gpa.free(cmd);
    const doc = p.ctx.document();
    const job = gpa.create(ShellJob) catch {
        gpa.free(cmd);
        return;
    };
    job.* = .{
        .ctx = p.ctx,
        .name = gpa.dupe(u8, p.name) catch {
            gpa.destroy(job);
            gpa.free(cmd);
            return;
        },
        .version = doc.version(gpa) catch {
            gpa.free(job.name);
            gpa.destroy(job);
            gpa.free(cmd);
            return;
        },
        .offset = p.ctx.editor().cursorOffset(),
        .cmd = cmd,
    };
    _ = loop.spawn(shellWork, job, .{ .ctx = job, .call = shellDeliver, .deinit = shellFree }) catch {
        shellFree(job);
    };
}

/// Off-thread: run `/bin/sh -c <cmd>`, return stdout trimmed of a trailing
/// newline. Failure yields empty (nothing inserted). Runs on the async pool
/// worker — proc.run synchronous there, no frame block.
fn shellWork(gpa: Allocator, ctx: ?*anyopaque) anyerror![]u8 {
    const job: *ShellJob = @ptrCast(@alignCast(ctx.?));
    var res = proc.run(gpa, &.{ "/bin/sh", "-c", job.cmd }, .{ .environ = shared.g_environ }) catch return gpa.alloc(u8, 0);
    defer res.deinit(gpa);
    return gpa.dupe(u8, std.mem.trimEnd(u8, res.stdout, "\n"));
}

/// Frame-thread delivery: rebase the captured offset and insert as the plugin
/// peer (grade-gated). A dead version or a view grade drops silently.
fn shellDeliver(ctx: ?*anyopaque, result: ?[]const u8) void {
    const job: *ShellJob = @ptrCast(@alignCast(ctx.?));
    const bytes = result orelse return;
    const gpa = job.ctx.gpa;
    const doc = job.ctx.document();
    if (!authority.gradeMin(doc.my_grant, .edit).canEdit()) return;
    const at = position.rebaseOffset(doc, job.version, job.offset, .right) orelse return;
    const pid = doc.peerNamed(gpa, job.name) catch return;
    doc.peerReplaceAll(gpa, pid, &.{.{ .range = .{ .start = at, .end = at }, .bytes = bytes }}) catch {};
}

fn shellFree(ctx: ?*anyopaque) void {
    const job: *ShellJob = @ptrCast(@alignCast(ctx.?));
    const gpa = job.ctx.gpa;
    gpa.free(job.name);
    gpa.free(job.version);
    gpa.free(job.cmd);
    gpa.destroy(job);
}

/// A deferred proc-to-buffer: run a command off-thread and replace a named
/// scratch buffer with its output. The buffer + author peer re-resolve by name
/// at delivery (surviving anything that moved them). `styler` is an optional
/// callback door: after the output lands and if the target is still the active
/// buffer, we fire the issuing plugin's `on_fill` export so it can classify the
/// fresh text into style spans. The plugin pointer is safe to hold — plugins
/// are resident for the app's life (the same residency `notifyActivate` relies
/// on); it is only ever called on the normal delivery path, never at teardown.
const ProcJob = struct {
    ctx: *command.Context,
    styler: *WasmPlugin, // fires on_fill after delivery (resident)
    plugin: []u8, // authors the buffer content
    buf: []u8, // target buffer name (found-or-created)
    cmd: []u8,
    append: bool = false, // append the output (a console) vs replace (a view)
};

/// Perm-gated (proc + timer): run `<cmd>` off the frame thread and replace the
/// scratch buffer named `<name>` with its stdout, authored as this plugin's
/// peer — the "tool output → a buffer" pattern (git status, grep, compile).
pub fn hProcToBuffer(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!p.perms[perm_proc] or !p.perms[perm_timer]) return;
    const loop = p.loop orelse return;
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    errdefer gpa.free(cmd);
    const name = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    errdefer gpa.free(name);
    const job = gpa.create(ProcJob) catch return;
    job.* = .{
        .ctx = p.ctx,
        .styler = p,
        .plugin = gpa.dupe(u8, p.name) catch {
            gpa.destroy(job);
            gpa.free(cmd);
            gpa.free(name);
            return;
        },
        .buf = name,
        .cmd = cmd,
    };
    _ = loop.spawn(procWork, job, .{ .ctx = job, .call = procDeliver, .deinit = procFree }) catch procFree(job);
}

/// Like `wl_proc_to_buffer` but APPENDS the output (a console/comint log) rather
/// than replacing the buffer.
pub fn hProcAppendBuffer(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!p.perms[perm_proc] or !p.perms[perm_timer]) return;
    const loop = p.loop orelse return;
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    errdefer gpa.free(cmd);
    const name = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    errdefer gpa.free(name);
    const job = gpa.create(ProcJob) catch return;
    job.* = .{
        .ctx = p.ctx,
        .styler = p,
        .plugin = gpa.dupe(u8, p.name) catch {
            gpa.destroy(job);
            gpa.free(cmd);
            gpa.free(name);
            return;
        },
        .buf = name,
        .cmd = cmd,
        .append = true,
    };
    _ = loop.spawn(procWork, job, .{ .ctx = job, .call = procDeliver, .deinit = procFree }) catch procFree(job);
}

fn procWork(gpa: Allocator, ctx: ?*anyopaque) anyerror![]u8 {
    const job: *ProcJob = @ptrCast(@alignCast(ctx.?));
    var res = proc.run(gpa, &.{ "/bin/sh", "-c", job.cmd }, .{ .environ = shared.g_environ }) catch return gpa.alloc(u8, 0);
    defer res.deinit(gpa);
    return gpa.dupe(u8, std.mem.trimEnd(u8, res.stdout, "\n"));
}

/// Frame-thread delivery: find-or-create the named buffer and replace its whole
/// content with the output, authored as the plugin peer (grade-gated).
fn procDeliver(ctx: ?*anyopaque, result: ?[]const u8) void {
    const job: *ProcJob = @ptrCast(@alignCast(ctx.?));
    const out = result orelse return;
    const gpa = job.ctx.gpa;
    const bufs = job.ctx.buffers;
    var target: ?*Buffers.Buffer = null;
    var it = bufs.iterator();
    while (it.next()) |b| {
        if (std.mem.eql(u8, b.name, job.buf)) {
            target = b;
            break;
        }
    }
    if (target == null) {
        const id = bufs.create(gpa, job.buf) catch return;
        target = bufs.get(id);
    }
    const b = target orelse return;
    // A proc-output buffer is a tool buffer: read-only, owned by the plugin that
    // renders it (its peer) — so only that renderer may edit it, and a user/vim
    // edit is refused at the edit door regardless of mode or split. Marked
    // unconditionally (not just on create) since dired/magit pre-create it.
    b.markReadOnly(gpa, job.plugin) catch {};
    const doc = &b.editor.doc;
    if (!authority.gradeMin(doc.my_grant, .edit).canEdit()) return;
    const pid = doc.peerNamed(gpa, job.plugin) catch return;
    const end = b.editor.text().byteLen();
    if (job.append) {
        // Append below the existing content (a console log), separated by a
        // newline once there is prior output.
        if (end > 0) {
            const sep = std.fmt.allocPrint(gpa, "\n{s}", .{out}) catch return;
            defer gpa.free(sep);
            doc.peerReplaceAll(gpa, pid, &.{.{ .range = .{ .start = end, .end = end }, .bytes = sep }}) catch {};
        } else {
            doc.peerReplaceAll(gpa, pid, &.{.{ .range = .{ .start = end, .end = end }, .bytes = out }}) catch {};
        }
    } else {
        doc.peerReplaceAll(gpa, pid, &.{.{ .range = .{ .start = 0, .end = end }, .bytes = out }}) catch {};
    }

    // The text has landed: give the issuing plugin a chance to classify it into
    // style spans (git/grep coloring). The guest's `on_fill` reads + paints the
    // ACTIVE buffer through the read/style membrane, so this only fires when the
    // just-filled buffer is still the focused one (the common case — a tool verb
    // focuses its buffer, then fills it). If focus moved on, we skip rather than
    // let the guest paint the wrong buffer; it renders plain, exactly as before.
    // A plugin without `on_fill` (grep-less builds, other tools) is a no-op.
    if (bufs.active() == b)
        job.styler.instance.callVoid("on_fill", &.{}) catch {}; // MissingExport → skip
}

fn procFree(ctx: ?*anyopaque) void {
    const job: *ProcJob = @ptrCast(@alignCast(ctx.?));
    const gpa = job.ctx.gpa;
    gpa.free(job.plugin);
    gpa.free(job.buf);
    gpa.free(job.cmd);
    gpa.destroy(job);
}

/// A deferred proc FILTER: run `[start,end)` through a command (which rewrites
/// a temp file in place, `{}` = its path) and replace the range with the
/// result. The edit is stamped at the version read and lands as the plugin
/// peer, so it rebases + merges like a concurrent editor (design §6.2 fmt).
const FilterJob = struct {
    ctx: *command.Context,
    plugin: []u8,
    version: []u8,
    start: usize,
    end: usize,
    cmd: []u8, // contains "{}" → the temp path
    content: []u8, // the captured input (owned)
    tmp: []u8,
};

var filter_counter: usize = 0;

/// Perm-gated (proc + timer): filter `[start,end)` through `<cmd>` (a `{}`
/// placeholder receives a temp file the range is written to, transformed in
/// place, and read back). Formatters (`zig fmt {}`, `prettier --write {}`) and
/// `vim !`-style filters both fit.
pub fn hProcFilter(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!p.perms[perm_proc] or !p.perms[perm_timer]) return;
    const loop = p.loop orelse return;
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    errdefer gpa.free(cmd);
    const rope = p.ctx.editor().text();
    const len = rope.byteLen();
    const s = @min(@as(usize, @intCast(args[2])), len);
    const e = @min(@as(usize, @intCast(args[3])), len);
    if (e < s) return;
    const content = gpa.alloc(u8, e - s) catch return;
    errdefer gpa.free(content);
    if (e > s) {
        var sr = rope.streamReader(.{ .start = s, .end = e }, &.{});
        sr.interface.readSliceAll(content) catch return;
    }
    const version = p.ctx.document().version(gpa) catch return;
    errdefer gpa.free(version);
    filter_counter += 1;
    const tmp = std.fmt.allocPrint(gpa, "/tmp/weft-filter-{d}-{d}", .{ filter_counter, s }) catch return;
    errdefer gpa.free(tmp);
    const job = gpa.create(FilterJob) catch return;
    job.* = .{
        .ctx = p.ctx,
        .plugin = gpa.dupe(u8, p.name) catch {
            gpa.destroy(job);
            return;
        },
        .version = version,
        .start = s,
        .end = e,
        .cmd = cmd,
        .content = content,
        .tmp = tmp,
    };
    _ = loop.spawn(filterWork, job, .{ .ctx = job, .call = filterDeliver, .deinit = filterFree }) catch filterFree(job);
}

fn filterWork(gpa: Allocator, ctx: ?*anyopaque) anyerror![]u8 {
    const job: *FilterJob = @ptrCast(@alignCast(ctx.?));
    // Write the input, run the command over it, read the result back. On ANY
    // failure return the ORIGINAL content, so the range is replaced with an
    // identical copy — never corrupted or emptied.
    file.writeBytes(gpa, job.tmp, job.content) catch return gpa.dupe(u8, job.content);
    const cmd = std.mem.replaceOwned(u8, gpa, job.cmd, "{}", job.tmp) catch return gpa.dupe(u8, job.content);
    defer gpa.free(cmd);
    var res = proc.run(gpa, &.{ "/bin/sh", "-c", cmd }, .{ .environ = shared.g_environ }) catch {
        file.deleteFile(gpa, job.tmp);
        return gpa.dupe(u8, job.content);
    };
    res.deinit(gpa); // in-place transform: the result is the file, not stdout
    const out = file.readAlloc(gpa, job.tmp) catch gpa.dupe(u8, job.content);
    file.deleteFile(gpa, job.tmp);
    return out;
}

fn filterDeliver(ctx: ?*anyopaque, result: ?[]const u8) void {
    const job: *FilterJob = @ptrCast(@alignCast(ctx.?));
    const out = result orelse return;
    const gpa = job.ctx.gpa;
    const doc = job.ctx.document();
    if (!authority.gradeMin(doc.my_grant, .edit).canEdit()) return;
    const rs = position.rebaseOffset(doc, job.version, job.start, .right) orelse return;
    const re = position.rebaseOffset(doc, job.version, job.end, .left) orelse return;
    const pid = doc.peerNamed(gpa, job.plugin) catch return;
    doc.peerReplaceAll(gpa, pid, &.{.{ .range = .{ .start = @min(rs, re), .end = @max(rs, re) }, .bytes = out }}) catch {};
}

fn filterFree(ctx: ?*anyopaque) void {
    const job: *FilterJob = @ptrCast(@alignCast(ctx.?));
    const gpa = job.ctx.gpa;
    gpa.free(job.plugin);
    gpa.free(job.version);
    gpa.free(job.cmd);
    gpa.free(job.content);
    gpa.free(job.tmp);
    gpa.destroy(job);
}
