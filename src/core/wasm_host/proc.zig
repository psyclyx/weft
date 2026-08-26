//! Perm-gated off-thread process effects (proc + timer): shell-insert at the
//! cursor, proc-to/append-buffer (tool output → a scratch buffer), and the
//! in-place range filter (formatters). Each schedules on the async loop and
//! lands its result on the frame thread at CRDT identity anchors, authored as
//! the plugin peer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const Buffers = @import("../Buffers.zig");
const proc = @import("../proc.zig");
const Document = @import("../Document.zig");
const file = @import("../file.zig");
const contract = @import("../membrane/contract.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const requirePerm = shared.requirePerm;

/// A deferred shell insert, owned across the frame→pool→frame hop. Holds no
/// plugin pointer — it resolves the generation-checked buffer captured at
/// dispatch and the peer by name at delivery, so a focus change cannot redirect
/// the edit and a closed/reused buffer safely makes it stale. Freed in every
/// terminal case by the sink's deinit.
///
/// Deferred jobs retain only the session-owned allocator/registry they need,
/// never a head's dispatch `Context`. Context is ambient plumbing and its
/// `document()` intentionally means "active now"; neither is a target token.
const ShellJob = struct {
    gpa: Allocator,
    buffers: *Buffers,
    buffer: Buffers.Ref,
    name: []u8,
    target: Document.EventAnchor,
    cmd: []u8, // the shell command line
};

// ── Raw persistent proc (wl_proc_spawn/send/read/close) ──────────────
// A bidirectional stdio channel whose stdout comes BACK to the guest (unlike
// the buffer-streaming repl sessions), so an in-guest protocol client — the
// `lsp` plugin — can deframe Content-Length messages. Mirrors the JS proc
// surface (quickjs cProc*) over the same proc_stream backend; handles index
// `plugin.proc_streams` and stay stable (a closed slot is nulled, not removed).
const proc_stream = @import("../proc_stream.zig");

fn streamAt(p: *WasmPlugin, h: i32) ?*proc_stream.ProcStream {
    if (h < 0 or h >= p.proc_streams.items.len) return null;
    return p.proc_streams.items[@intCast(h)];
}

/// `procSpawn(cmd) -> handle` (perm proc, trap on deny) (or -1 if unavailable).
/// Spawns a persistent subprocess inheriting the host environ + cwd; its
/// stdout is buffered for `wl_proc_read`.
pub fn hProcSpawn(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!requirePerm(p, caller, .proc)) return;
    const pool = p.pool orelse {
        results[0] = -1;
        return;
    };
    const cmd = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(cmd);
    const s = proc_stream.ProcStream.start(p.gpa, pool, cmd, null, shared.g_environ) catch {
        results[0] = -1;
        return;
    };
    const h: i32 = @intCast(p.proc_streams.items.len);
    p.proc_streams.append(p.gpa, s) catch {
        s.deinit();
        results[0] = -1;
        return;
    };
    results[0] = h;
}

/// `procSend(handle, bytes)`: write to the subprocess's stdin.
pub fn hProcSend(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const s = streamAt(p, args[0]) orelse return;
    const bytes = caller.readMemory(p.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer p.gpa.free(bytes);
    s.send(bytes);
}

/// `procRead(handle, out, cap) -> n`: drain up to `cap` buffered stdout bytes.
pub fn hProcRead(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const s = streamAt(p, args[0]) orelse {
        results[0] = 0;
        return;
    };
    const cap: usize = @intCast(args[2]);
    const buf = p.gpa.alloc(u8, cap) catch {
        results[0] = 0;
        return;
    };
    defer p.gpa.free(buf);
    const n = s.read(buf);
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(cap), buf[0..n]) catch 0);
}

/// `cwd(out, cap) -> n`: the process working directory, for building absolute
/// `file://` uris (a language server resolves relative uris to absolute, so a
/// client must speak absolute to match returned locations).
pub fn hCwd(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = data;
    var buf: [4096]u8 = undefined;
    const rc = std.os.linux.getcwd(&buf, buf.len);
    if (@as(isize, @bitCast(rc)) < 0) {
        results[0] = 0;
        return;
    }
    const path = std.mem.sliceTo(buf[0..rc], 0);
    results[0] = @intCast(caller.writeMemory(@intCast(args[0]), @intCast(args[1]), path) catch 0);
}

/// `procClose(handle)`: kill the subprocess; the slot stays null for stability.
pub fn hProcClose(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h = args[0];
    if (streamAt(p, h)) |s| {
        s.deinit();
        p.proc_streams.items[@intCast(h)] = null;
    }
}

/// Perm-gated (proc + timer): run `<cmd>` off the frame thread and insert its
/// stdout at the cursor when it finishes — anchored if the buffer moved,
/// authored as this plugin's peer. The membrane form of shell.zig's
/// `editLater(runCmd, cmd)`: same async target + authority, but the proc
/// body runs host-side (the design's "route proc through the host import").
pub fn hShellInsert(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    // Trap on deny — no ghost second result if the plugin didn't request both.
    if (!requirePerm(p, caller, .proc)) return;
    if (!requirePerm(p, caller, .timer)) return;
    const loop = p.loop orelse return;
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    var cmd_owned = true;
    defer if (cmd_owned) gpa.free(cmd);
    const active_ctx = p.activeCtx();
    const buffer = active_ctx.buffers.active();
    const editor = buffer.textEditor() orelse return;
    const doc = &editor.doc;
    const target = doc.exportAnchor(gpa, editor.cursorOffset(), .before) catch return;
    var target_owned = true;
    defer if (target_owned) gpa.free(target.agent);
    const job = gpa.create(ShellJob) catch {
        return;
    };
    var job_owned = true;
    defer if (job_owned) gpa.destroy(job);
    const name = gpa.dupe(u8, p.name) catch return;
    job.* = .{
        .gpa = gpa,
        .buffers = active_ctx.buffers,
        .buffer = buffer.ref(),
        .name = name,
        .target = target,
        .cmd = cmd,
    };
    cmd_owned = false;
    target_owned = false;
    job_owned = false;
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

/// Frame-thread delivery: resolve the captured CRDT identity and insert as the
/// plugin peer (grade-gated). A foreign/compacted target or view grade drops.
fn shellDeliver(ctx: ?*anyopaque, result: ?[]const u8) void {
    const job: *ShellJob = @ptrCast(@alignCast(ctx.?));
    const bytes = result orelse return;
    const gpa = job.gpa;
    const buffer = job.buffers.resolve(job.buffer) orelse return;
    const doc = &(buffer.textEditor() orelse return).doc;
    var resolved: [1]usize = undefined;
    doc.resolveAnchors(gpa, &.{job.target}, &resolved) catch return;
    const at = resolved[0];
    command.renderInto(gpa, doc, .plugin, job.name, &.{.{ .range = .{ .start = at, .end = at }, .bytes = bytes }}) catch return;
}

fn shellFree(ctx: ?*anyopaque) void {
    const job: *ShellJob = @ptrCast(@alignCast(ctx.?));
    const gpa = job.gpa;
    gpa.free(job.name);
    gpa.free(job.target.agent);
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
    gpa: Allocator,
    buffers: *Buffers,
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
    if (!requirePerm(p, caller, .proc)) return;
    if (!requirePerm(p, caller, .timer)) return;
    const loop = p.loop orelse return;
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    errdefer gpa.free(cmd);
    const name = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    errdefer gpa.free(name);
    const job = gpa.create(ProcJob) catch return;
    job.* = .{
        .gpa = gpa,
        .buffers = p.activeCtx().buffers,
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
    if (!requirePerm(p, caller, .proc)) return;
    if (!requirePerm(p, caller, .timer)) return;
    const loop = p.loop orelse return;
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    errdefer gpa.free(cmd);
    const name = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    errdefer gpa.free(name);
    const job = gpa.create(ProcJob) catch return;
    job.* = .{
        .gpa = gpa,
        .buffers = p.activeCtx().buffers,
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
    const gpa = job.gpa;
    const bufs = job.buffers;
    // A buffer proc CREATES is a plain tool sink (grep/make output) → read-only.
    // A PRE-created buffer keeps whatever the plugin declared (a projection
    // marks itself read-only via weft.readOnly; an editable one like
    // *git-commit* stays writable) — so create-branch marks, find-branch doesn't.
    const b = if (bufs.findByName(job.buf)) |id|
        (bufs.get(id) orelse return)
    else blk: {
        const nb = bufs.get(bufs.create(gpa, job.buf) catch return) orelse return;
        nb.read_only = true;
        break :blk nb;
    };
    const editor = b.textEditor() orelse return;
    const doc = &editor.doc;
    const end = editor.text().byteLen();
    if (job.append) {
        // Append below the existing content (a console log), separated by a
        // newline once there is prior output.
        if (end > 0) {
            const sep = std.fmt.allocPrint(gpa, "\n{s}", .{out}) catch return;
            defer gpa.free(sep);
            command.renderInto(gpa, doc, .plugin, job.plugin, &.{.{ .range = .{ .start = end, .end = end }, .bytes = sep }}) catch {};
        } else {
            command.renderInto(gpa, doc, .plugin, job.plugin, &.{.{ .range = .{ .start = end, .end = end }, .bytes = out }}) catch {};
        }
    } else {
        command.renderInto(gpa, doc, .plugin, job.plugin, &.{.{ .range = .{ .start = 0, .end = end }, .bytes = out }}) catch {};
    }

    // The text has landed: give the issuing plugin a chance to classify it into
    // style spans (git/grep coloring). The guest's `on_fill` reads + paints the
    // ACTIVE buffer through the read/style membrane, so this only fires when the
    // just-filled buffer is still the focused one (the common case — a tool verb
    // focuses its buffer, then fills it). If focus moved on, we skip rather than
    // let the guest paint the wrong buffer; it renders plain, exactly as before.
    // A plugin without `on_fill` (grep-less builds, other tools) is a no-op.
    if (bufs.active() == b)
        contract.callOptionalExport("on_fill", &job.styler.instance, .{}) catch {}; // MissingExport → skip
}

fn procFree(ctx: ?*anyopaque) void {
    const job: *ProcJob = @ptrCast(@alignCast(ctx.?));
    const gpa = job.gpa;
    gpa.free(job.plugin);
    gpa.free(job.buf);
    gpa.free(job.cmd);
    gpa.destroy(job);
}

/// A deferred proc FILTER: run `[start,end)` through a command (which rewrites
/// a temp file in place, `{}` = its path) and replace the range with the
/// result. The range is captured as CRDT identities and lands as the plugin
/// peer, so it follows concurrent edits without a version clock.
const FilterJob = struct {
    gpa: Allocator,
    buffers: *Buffers,
    buffer: Buffers.Ref,
    plugin: []u8,
    start: Document.EventAnchor,
    end: Document.EventAnchor,
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
    if (!requirePerm(p, caller, .proc)) return;
    if (!requirePerm(p, caller, .timer)) return;
    const loop = p.loop orelse return;
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    var cmd_owned = true;
    defer if (cmd_owned) gpa.free(cmd);
    const active_ctx = p.activeCtx();
    const buffer = active_ctx.buffers.active();
    const editor = buffer.textEditor() orelse return;
    const rope = editor.text();
    const len = rope.byteLen();
    const s = @min(@as(usize, @intCast(args[2])), len);
    const e = @min(@as(usize, @intCast(args[3])), len);
    if (e < s) return;
    const content = gpa.alloc(u8, e - s) catch return;
    var content_owned = true;
    defer if (content_owned) gpa.free(content);
    if (e > s) {
        var sr = rope.streamReader(.{ .start = s, .end = e }, &.{});
        sr.interface.readSliceAll(content) catch return;
    }
    const start = editor.doc.exportAnchor(gpa, s, .before) catch return;
    var start_owned = true;
    defer if (start_owned) gpa.free(start.agent);
    const end = editor.doc.exportAnchor(gpa, e, .after) catch return;
    var end_owned = true;
    defer if (end_owned) gpa.free(end.agent);
    filter_counter += 1;
    const tmp = std.fmt.allocPrint(gpa, "/tmp/weft-filter-{d}-{d}", .{ filter_counter, s }) catch return;
    var tmp_owned = true;
    defer if (tmp_owned) gpa.free(tmp);
    const job = gpa.create(FilterJob) catch return;
    var job_owned = true;
    defer if (job_owned) gpa.destroy(job);
    const plugin = gpa.dupe(u8, p.name) catch return;
    job.* = .{
        .gpa = gpa,
        .buffers = active_ctx.buffers,
        .buffer = buffer.ref(),
        .plugin = plugin,
        .start = start,
        .end = end,
        .cmd = cmd,
        .content = content,
        .tmp = tmp,
    };
    cmd_owned = false;
    content_owned = false;
    start_owned = false;
    end_owned = false;
    tmp_owned = false;
    job_owned = false;
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
    const gpa = job.gpa;
    const buffer = job.buffers.resolve(job.buffer) orelse return;
    const doc = &(buffer.textEditor() orelse return).doc;
    var resolved: [2]usize = undefined;
    doc.resolveAnchors(gpa, &.{ job.start, job.end }, &resolved) catch return;
    const rs = resolved[0];
    const re = resolved[1];
    command.renderInto(gpa, doc, .plugin, job.plugin, &.{.{ .range = .{ .start = @min(rs, re), .end = @max(rs, re) }, .bytes = out }}) catch return;
}

fn filterFree(ctx: ?*anyopaque) void {
    const job: *FilterJob = @ptrCast(@alignCast(ctx.?));
    const gpa = job.gpa;
    gpa.free(job.plugin);
    gpa.free(job.start.agent);
    gpa.free(job.end.agent);
    gpa.free(job.cmd);
    gpa.free(job.content);
    gpa.free(job.tmp);
    gpa.destroy(job);
}
