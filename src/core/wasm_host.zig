//! wasm_host — the `weft.*` host-import table: one small function per abi.Abi
//! method the guest shim (src/guest/weft.zig) imports, each marshalling to
//! command.Context across the sandbox membrane, plus the trampolines that
//! dispatch back into the guest (commands, pick accept, completion provider)
//! and the deferred shell-insert machinery. Split from wasm_abi.zig — which
//! owns the WasmPlugin lifecycle + handshake — to keep each file focused on
//! one concern; the two @import each other (Zig permits the cycle).

const std = @import("std");
const Allocator = std.mem.Allocator;

const wasm = @import("wasm.zig");
const command = @import("command.zig");
const capability = @import("capability.zig");
const pick_mod = @import("pick.zig");
const fs_source = @import("fs_source.zig");
const Buffers = @import("Buffers.zig");
const syntax = @import("syntax.zig");
const subbuffer = @import("subbuffer.zig");
const async_loop = @import("async.zig");
const proc = @import("proc.zig");
const authority = @import("authority.zig");
const position = @import("position.zig");
const Document = @import("Document.zig");
const Editor = @import("Editor.zig");

// The lifecycle side owns these; we operate on them.
const wasm_abi = @import("wasm_abi.zig");
const WasmPlugin = wasm_abi.WasmPlugin;
const WasmCmd = wasm_abi.WasmCmd;
const PendingItem = wasm_abi.PendingItem;
const WasmBoundPick = wasm_abi.WasmBoundPick;

/// Bind the full `weft.*` host-import membrane (the guest-side surface in
/// src/guest/weft.zig). One import per abi.Abi method the shim exposes; each
/// is small and tagged with the plugin so the callback recovers its state.
pub fn defineImports(linker: *wasm.Linker, p: *WasmPlugin) !void {
    const d = struct {
        fn f(l: *wasm.Linker, comptime nm: []const u8, np: usize, nr: usize, func: wasm.Linker.HostFn, data: *WasmPlugin) !void {
            try l.defineFn("weft", nm, np, nr, func, data);
        }
    }.f;
    // Group A: core.
    try d(linker, "wl_log", 3, 0, hLog, p);
    // Describe phase: declarations.
    try d(linker, "wl_declare_command", 2, 0, hDeclareCommand, p);
    try d(linker, "wl_declare_capability", 2, 0, hDeclareCapability, p);
    try d(linker, "wl_request_perm", 1, 0, hRequestPerm, p);
    // Group B: read-only.
    try d(linker, "wl_cursor", 0, 1, hCursor, p);
    try d(linker, "wl_byte_len", 0, 1, hByteLen, p);
    try d(linker, "wl_slice", 4, 1, hSlice, p);
    try d(linker, "wl_line_at", 2, 0, hLineAt, p);
    try d(linker, "wl_selection", 1, 1, hSelection, p);
    try d(linker, "wl_path", 2, 1, hPath, p);
    // Group B: the native `editor` surface (pure step primitive).
    try d(linker, "wl_editor_step", 3, 1, hEditorStep, p);
    try d(linker, "wl_set_selection", 2, 0, hSetSelection, p);
    // Group C: write.
    try d(linker, "wl_edit", 4, 0, hEdit, p);
    try d(linker, "wl_register", 2, 1, hRegister, p);
    try d(linker, "wl_jump", 1, 0, hJump, p);
    // Stamped ranges ([FIX 1/3]): a motion returns one, an operator awaits +
    // applies it. Handles cross; the version token stays host-side.
    try d(linker, "wl_stamp_range", 2, 1, hStampRange, p);
    try d(linker, "wl_set_result_range", 1, 0, hSetResultRange, p);
    try d(linker, "wl_run_range", 2, 1, hRunRange, p);
    try d(linker, "wl_range_ends", 2, 1, hRangeEnds, p);
    try d(linker, "wl_run_range_arg", 3, 0, hRunRangeArg, p);
    try d(linker, "wl_arg_range", 1, 1, hArgRange, p);
    try d(linker, "wl_edit_range", 3, 0, hEditRange, p);
    // Group E: admin (kv).
    try d(linker, "wl_kv_get", 4, 1, hKvGet, p);
    try d(linker, "wl_kv_put", 4, 0, hKvPut, p);
    // Config surface.
    try d(linker, "wl_echo", 2, 0, hEcho, p);
    // Command args in + result out (during on_command).
    try d(linker, "wl_arg_count", 0, 1, hArgCount, p);
    try d(linker, "wl_arg_int", 1, 1, hArgInt, p);
    try d(linker, "wl_arg_str", 3, 1, hArgStr, p);
    try d(linker, "wl_set_result_int", 1, 0, hSetResultInt, p);
    try d(linker, "wl_set_result_str", 2, 0, hSetResultStr, p);
    // Config surface (the local plane).
    try d(linker, "wl_bind_key", 6, 0, hBindKey, p);
    try d(linker, "wl_set_mode", 2, 0, hSetMode, p);
    try d(linker, "wl_set_fallback", 4, 0, hSetFallback, p);
    try d(linker, "wl_text_input", 5, 0, hTextInput, p);
    try d(linker, "wl_menu_mode", 2, 0, hMenuMode, p);
    try d(linker, "wl_run", 2, 0, hRun, p);
    try d(linker, "wl_run_int", 3, 0, hRunInt, p);
    try d(linker, "wl_run_str", 4, 0, hRunStr, p);
    try d(linker, "wl_run_str2", 6, 0, hRunStr2, p);
    // Introspection.
    try d(linker, "wl_command_count", 0, 1, hCommandCount, p);
    try d(linker, "wl_command_name", 3, 1, hCommandName, p);
    try d(linker, "wl_command_summary", 3, 1, hCommandSummary, p);
    try d(linker, "wl_buffer_count", 0, 1, hBufferCount, p);
    try d(linker, "wl_buffer_id", 1, 1, hBufferId, p);
    try d(linker, "wl_buffer_name", 3, 1, hBufferName, p);
    try d(linker, "wl_buffer_active", 1, 1, hBufferActive, p);
    try d(linker, "wl_buffer_readonly", 1, 1, hBufferReadonly, p);
    // Pick.
    try d(linker, "wl_pick_begin", 3, 0, hPickBegin, p);
    try d(linker, "wl_pick_add", 4, 0, hPickAdd, p);
    try d(linker, "wl_pick_end", 0, 0, hPickEnd, p);
    try d(linker, "wl_open_file_pick", 5, 0, hOpenFilePick, p);
    try d(linker, "wl_pick_choice", 2, 1, hPickChoice, p);
    try d(linker, "wl_pick_choice_index", 0, 1, hPickChoiceIndex, p);
    // Completion provider (host↔guest data-gather).
    try d(linker, "wl_provide_completion", 0, 0, hProvideCompletion, p);
    try d(linker, "wl_completion_prefix", 2, 1, hCompletionPrefix, p);
    try d(linker, "wl_push_completion", 2, 0, hPushCompletion, p);
    // Structural read + subbuffers.
    try d(linker, "wl_node_at", 4, 1, hNodeAt, p);
    // syntax.query (design §4): the tree stays host-side; captures/nodes cross.
    try d(linker, "wl_node_enclosing", 5, 1, hNodeEnclosing, p);
    try d(linker, "wl_query", 4, 1, hQuery, p);
    try d(linker, "wl_query_capture", 4, 1, hQueryCapture, p);
    try d(linker, "wl_node_children", 1, 1, hNodeChildren, p);
    try d(linker, "wl_claim_subbuffer", 2, 1, hClaimSubbuffer, p);
    try d(linker, "wl_subbuffer_put_fact", 5, 0, hSubbufferPutFact, p);
    // Effects (perm-gated): shell insert — the membrane form of editLater
    // with a host-side proc body (the guest can't run off-thread itself).
    try d(linker, "wl_shell_insert", 2, 0, hShellInsert, p);
    try d(linker, "wl_proc_to_buffer", 4, 0, hProcToBuffer, p);
}

pub const perm_proc = 3;
pub const perm_timer = 4;

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
fn hShellInsert(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
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
    var res = proc.run(gpa, &.{ "/bin/sh", "-c", job.cmd }, .{}) catch return gpa.alloc(u8, 0);
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
/// scratch buffer with its output. Like ShellJob it holds NO plugin pointer —
/// it re-resolves the buffer + peer by name at delivery, so it survives the
/// plugin unloading mid-flight (no use-after-free from a guest callback).
const ProcJob = struct {
    ctx: *command.Context,
    plugin: []u8, // authors the buffer content
    buf: []u8, // target buffer name (found-or-created)
    cmd: []u8,
};

/// Perm-gated (proc + timer): run `<cmd>` off the frame thread and replace the
/// scratch buffer named `<name>` with its stdout, authored as this plugin's
/// peer — the "tool output → a buffer" pattern (git status, grep, compile).
fn hProcToBuffer(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
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

fn procWork(gpa: Allocator, ctx: ?*anyopaque) anyerror![]u8 {
    const job: *ProcJob = @ptrCast(@alignCast(ctx.?));
    var res = proc.run(gpa, &.{ "/bin/sh", "-c", job.cmd }, .{}) catch return gpa.alloc(u8, 0);
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
        if (target) |b| b.read_only = true; // a tool buffer
    }
    const b = target orelse return;
    const doc = &b.editor.doc;
    if (!authority.gradeMin(doc.my_grant, .edit).canEdit()) return;
    const pid = doc.peerNamed(gpa, job.plugin) catch return;
    const end = b.editor.text().byteLen();
    doc.peerReplaceAll(gpa, pid, &.{.{ .range = .{ .start = 0, .end = end }, .bytes = out }}) catch {};
}

fn procFree(ctx: ?*anyopaque) void {
    const job: *ProcJob = @ptrCast(@alignCast(ctx.?));
    const gpa = job.ctx.gpa;
    gpa.free(job.plugin);
    gpa.free(job.buf);
    gpa.free(job.cmd);
    gpa.destroy(job);
}

pub fn resolvePeerWp(ctx: *anyopaque, doc: *Document) Document.AddPeerError!Document.PeerId {
    const p: *WasmPlugin = @ptrCast(@alignCast(ctx));
    return doc.peerNamed(p.gpa, p.name);
}

// ── Host import table: one small function per abi.Abi method ──────────

// Group A: core.
fn hLog(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const msg = caller.readMemory(p.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer p.gpa.free(msg);
    switch (args[0]) {
        2 => std.log.warn("{s}", .{msg}),
        3 => std.log.err("{s}", .{msg}),
        else => std.log.info("{s}", .{msg}),
    }
}

// Describe phase: declarations recorded only while describing.
fn hDeclareCommand(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (p.phase != .describing) return;
    const name = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    p.declared.append(p.gpa, name) catch {
        p.gpa.free(name);
        return;
    };
}

fn hDeclareCapability(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (p.phase != .describing) return;
    const name = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    p.declared_caps.append(p.gpa, name) catch {
        p.gpa.free(name);
        return;
    };
}

fn hRequestPerm(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (p.phase != .describing) return;
    const idx: usize = @intCast(args[0]);
    if (idx < wasm_abi.perm_count) p.perms[idx] = true;
}

// Group B: read-only.
fn hCursor(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(p.ctx.editor().cursorOffset());
}

fn hByteLen(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(p.ctx.editor().text().byteLen());
}

fn hSlice(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const rope = p.ctx.editor().text();
    const len = rope.byteLen();
    const s = @min(@as(usize, @intCast(args[0])), len);
    const e = @min(@as(usize, @intCast(args[1])), len);
    if (e <= s) {
        results[0] = 0;
        return;
    }
    const buf = p.gpa.alloc(u8, e - s) catch {
        results[0] = 0;
        return;
    };
    defer p.gpa.free(buf);
    var sr = rope.streamReader(.{ .start = s, .end = e }, &.{});
    sr.interface.readSliceAll(buf) catch {
        results[0] = 0;
        return;
    };
    const n = caller.writeMemory(@intCast(args[2]), @intCast(args[3]), buf) catch 0;
    results[0] = @intCast(n);
}

fn hLineAt(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const rope = p.ctx.editor().text();
    const row = rope.offsetToPoint(@min(@as(usize, @intCast(args[0])), rope.byteLen())).row;
    const line = rope.lineRange(row);
    const pair = [2]u32{ @intCast(line.start), @intCast(line.end) };
    _ = caller.writeMemory(@intCast(args[1]), 8, std.mem.asBytes(&pair)) catch {};
}

fn hSelection(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const sel = p.ctx.editor().selectedRange() orelse {
        results[0] = 0;
        return;
    };
    const pair = [2]u32{ @intCast(sel.start), @intCast(sel.end) };
    _ = caller.writeMemory(@intCast(args[0]), 8, std.mem.asBytes(&pair)) catch {};
    results[0] = 1;
}

fn hPath(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const path = p.ctx.editor().backingPath() orelse {
        results[0] = -1;
        return;
    };
    const n = caller.writeMemory(@intCast(args[0]), @intCast(args[1]), path) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(n);
}

// Group C: write.
fn hEdit(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const bytes = caller.readMemory(p.gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer p.gpa.free(bytes);
    const saved = p.ctx.principal;
    p.ctx.principal = p.principal();
    defer p.ctx.principal = saved;
    p.ctx.edit(.{ .start = @intCast(args[0]), .end = @intCast(args[1]) }, bytes) catch {};
}

fn hRegister(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const cname = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    // Cross-check against the manifest: an undeclared command fails the load.
    if (!p.declaresCommand(cname)) {
        gpa.free(cname);
        p.load_error = error.UndeclaredCommand;
        results[0] = -1;
        return;
    }
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
    _ = p.ctx.commands.bind(gpa, wc.name, .{
        .name = wc.name,
        .summary = "",
        .args = &.{},
        .handler = wpCmdTrampoline,
        .data = wc,
    }) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(wc.id);
}

fn hJump(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const ed = p.ctx.editor();
    ed.placeCursor(@min(@as(usize, @intCast(args[0])), ed.text().byteLen()));
}

// ── The native `editor` surface + stamped-range membrane ([FIX 1/3]) ──

/// `editor.step(from, dir, kind) -> offset`: the pure step primitive a motion
/// plugin composes (char boundary or byte-column line motion), no cursor move.
fn hEditorStep(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const from: usize = @intCast(args[0]);
    const dir: Editor.StepDir = @enumFromInt(@as(u32, @intCast(args[1])));
    const kind: Editor.StepKind = @enumFromInt(@as(u32, @intCast(args[2])));
    results[0] = @intCast(p.ctx.editor().stepOffset(from, dir, kind));
}

/// `editor.setSelection(start, end)`: select `[start, end)` (mark at start,
/// cursor at end). The native selection write-half, composed from placeCursor
/// + setMark.
fn hSetSelection(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const ed = p.ctx.editor();
    const len = ed.text().byteLen();
    ed.placeCursor(@min(@as(usize, @intCast(args[0])), len));
    ed.setMark(p.gpa) catch {};
    ed.placeCursor(@min(@as(usize, @intCast(args[1])), len));
}

/// Stamp `[start, end)` at the current document version and return an opaque
/// handle into this plugin's per-dispatch table. The one way a guest builds a
/// range (a motion's target, or a linewise op's line span). -1 on failure.
fn hStampRange(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const v = p.ctx.document().version(p.gpa) catch {
        results[0] = -1;
        return;
    };
    const h = p.pushRange(v, @intCast(args[0]), @intCast(args[1])) catch {
        p.gpa.free(v);
        results[0] = -1;
        return;
    };
    results[0] = @intCast(h);
}

/// A motion sets its result to a `range` Value from a handle it stamped.
fn hSetResultRange(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h: usize = @intCast(args[0]);
    if (h >= p.stamps.items.len) return;
    p.result = .{ .range = p.stamps.items[h].range };
}

/// Run a command by name; if it returns a `range` Value (a motion), rebase it
/// to the current head, re-stamp into THIS plugin's table, and return the
/// handle. -1 if the command produced no range. This is how an operator (or
/// vim) "awaits a motion by name" (design §6.1). Synchronous motions only for
/// now — a pending/async range would preserve the original version instead.
fn hRunRange(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const cmd = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(cmd);
    const rv = command.run(p.ctx.commands, p.ctx, cmd, &.{}) catch {
        results[0] = -1;
        return;
    };
    if (rv != .range) {
        results[0] = -1;
        return;
    }
    const cur = rv.range.rebase(p.ctx.document()) orelse {
        results[0] = -1;
        return;
    };
    const v = p.ctx.document().version(p.gpa) catch {
        results[0] = -1;
        return;
    };
    const h = p.pushRange(v, cur.start, cur.end) catch {
        p.gpa.free(v);
        results[0] = -1;
        return;
    };
    results[0] = @intCast(h);
}

/// Resolve a stamped-range handle to its current `[start, end)` (two u32 into
/// the guest). -1 if the handle is unknown or the range rebased away.
fn hRangeEnds(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h: usize = @intCast(args[0]);
    if (h >= p.stamps.items.len) {
        results[0] = -1;
        return;
    }
    const cur = p.stamps.items[h].range.rebase(p.ctx.document()) orelse {
        results[0] = -1;
        return;
    };
    const pair = [2]u32{ @intCast(cur.start), @intCast(cur.end) };
    _ = caller.writeMemory(@intCast(args[1]), 8, std.mem.asBytes(&pair)) catch {
        results[0] = -1;
        return;
    };
    results[0] = 0;
}

/// Run a command passing a stamped range (by handle) as its single arg — how
/// vim hands a motion's range to an operator (`op.delete`, …).
fn hRunRangeArg(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const cmd = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(cmd);
    const h: usize = @intCast(args[2]);
    if (h >= p.stamps.items.len) return;
    const rv = command.Value{ .range = p.stamps.items[h].range };
    _ = command.run(p.ctx.commands, p.ctx, cmd, &.{rv}) catch {};
}

/// An operator reads its `range` arg: rebase to head, re-stamp into this
/// plugin's table, return the handle. -1 if arg `i` is not a range.
fn hArgRange(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const i: usize = @intCast(args[0]);
    if (i >= p.cur_args.len or p.cur_args[i] != .range) {
        results[0] = -1;
        return;
    }
    const cur = p.cur_args[i].range.rebase(p.ctx.document()) orelse {
        results[0] = -1;
        return;
    };
    const v = p.ctx.document().version(p.gpa) catch {
        results[0] = -1;
        return;
    };
    const h = p.pushRange(v, cur.start, cur.end) catch {
        p.gpa.free(v);
        results[0] = -1;
        return;
    };
    results[0] = @intCast(h);
}

/// Apply an edit over a stamped-range handle: rebase to head, then the gated
/// `ctx.edit` door authored as this plugin's peer (same gate/attribution as
/// `wl_edit`). A `view` grade fails inside `ctx.edit` — zero permission code
/// in the operator.
fn hEditRange(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h: usize = @intCast(args[0]);
    if (h >= p.stamps.items.len) return;
    const cur = p.stamps.items[h].range.rebase(p.ctx.document()) orelse return;
    const bytes = caller.readMemory(p.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer p.gpa.free(bytes);
    const saved = p.ctx.principal;
    p.ctx.principal = p.principal();
    defer p.ctx.principal = saved;
    p.ctx.edit(.{ .start = cur.start, .end = cur.end }, bytes) catch {};
}

// Group E: admin (kv), namespaced by plugin name.
fn hKvGet(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const store = p.store orelse {
        results[0] = -1;
        return;
    };
    const key = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(key);
    const val = store.get(p.name, key) orelse {
        results[0] = -1;
        return;
    };
    const n = caller.writeMemory(@intCast(args[2]), @intCast(args[3]), val) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(n);
}

fn hKvPut(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const store = p.store orelse return;
    const key = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(key);
    const val = caller.readMemory(p.gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer p.gpa.free(val);
    store.put(p.gpa, p.name, key, val) catch {};
}

// Config surface.
fn hEcho(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const msg = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(msg);
    p.ctx.echo.clearRetainingCapacity();
    p.ctx.echo.appendSlice(p.gpa, msg) catch {};
}

// Command args in + result out. Integers cross as i32 — the membrane word.
fn hArgCount(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(p.cur_args.len);
}

fn hArgInt(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const i: usize = @intCast(args[0]);
    results[0] = if (i < p.cur_args.len and p.cur_args[i] == .integer)
        @truncate(p.cur_args[i].integer)
    else
        0;
}

fn hArgStr(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const i: usize = @intCast(args[0]);
    if (i >= p.cur_args.len or p.cur_args[i] != .string) {
        results[0] = -1;
        return;
    }
    const n = caller.writeMemory(@intCast(args[1]), @intCast(args[2]), p.cur_args[i].string) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(n);
}

fn hSetResultInt(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.result = .{ .integer = args[0] };
}

fn hSetResultStr(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const bytes = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(bytes);
    p.result_buf.clearRetainingCapacity();
    p.result_buf.appendSlice(p.gpa, bytes) catch return;
    p.result = .{ .string = p.result_buf.items };
}

// Config surface (the local plane) — each mirrors an abi.Abi config method.
fn hBindKey(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const mode = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(mode);
    const key = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(key);
    const cmd = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer gpa.free(cmd);
    // A plugin binds at the plugin tier, owned by its name (so a config bind
    // shadows it and equal-tier collisions between two plugins are surfaced).
    const Keymap = @import("Keymap.zig");
    p.ctx.keymap.bind(gpa, mode, key, cmd, Keymap.prio_plugin, p.name) catch {};
}

fn hSetMode(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const mode = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(mode);
    p.ctx.keymap.setMode(p.gpa, mode) catch {};
}

fn hSetFallback(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const mode = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(mode);
    const parent = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(parent);
    p.ctx.keymap.setFallback(gpa, mode, parent) catch {};
}

fn hTextInput(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const mode = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(mode);
    if (args[4] == 0) {
        p.ctx.keymap.setTextCommand(gpa, mode, null) catch {};
        return;
    }
    const cmd = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(cmd);
    p.ctx.keymap.setTextCommand(gpa, mode, cmd) catch {};
}

fn hMenuMode(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const mode = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(mode);
    p.ctx.keymap.markMenuMode(p.gpa, mode) catch {};
}

fn hRun(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const cmd = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(cmd);
    _ = command.run(p.ctx.commands, p.ctx, cmd, &.{}) catch {};
}

fn hRunInt(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const cmd = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(cmd);
    _ = command.run(p.ctx.commands, p.ctx, cmd, &.{.{ .integer = args[2] }}) catch {};
}

fn hRunStr(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(cmd);
    const s = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(s);
    _ = command.run(p.ctx.commands, p.ctx, cmd, &.{.{ .string = s }}) catch {};
}

fn hRunStr2(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(cmd);
    const a = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(a);
    const b = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer gpa.free(b);
    _ = command.run(p.ctx.commands, p.ctx, cmd, &.{ .{ .string = a }, .{ .string = b } }) catch {};
}

// Introspection — command registry + open buffers.
fn hCommandCount(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(p.ctx.commands.count());
}

fn hCommandName(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const n: command.Commands.Name = @enumFromInt(@as(usize, @intCast(args[0])));
    if (p.ctx.commands.lookup(n) == null) {
        results[0] = -1;
        return;
    }
    const name = p.ctx.commands.nameOf(n);
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), name) catch 0);
}

fn hCommandSummary(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const n: command.Commands.Name = @enumFromInt(@as(usize, @intCast(args[0])));
    const cmd = p.ctx.commands.lookup(n) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), cmd.summary) catch 0);
}

/// The i-th open buffer, or null (O(i) walk — the introspection path).
fn bufferAtIndex(p: *WasmPlugin, i: usize) ?*@import("Buffers.zig").Buffer {
    var it = p.ctx.buffers.iterator();
    var j: usize = 0;
    while (it.next()) |b| : (j += 1) if (j == i) return b;
    return null;
}

fn hBufferCount(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(p.ctx.buffers.count());
}

fn hBufferId(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const b = bufferAtIndex(p, @intCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(b.id);
}

fn hBufferName(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const b = bufferAtIndex(p, @intCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), b.name) catch 0);
}

fn hBufferActive(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const b = bufferAtIndex(p, @intCast(args[0]));
    results[0] = if (b != null and b == p.ctx.buffers.active()) 1 else 0;
}

fn hBufferReadonly(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const b = bufferAtIndex(p, @intCast(args[0]));
    results[0] = if (b != null and b.?.read_only) 1 else 0;
}

// Pick — accumulate items between begin/end, then open with an accept
// trampoline that dispatches to the guest's on_pick_accept.
fn hPickBegin(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    for (p.pick_items.items) |it| {
        gpa.free(it.text);
        gpa.free(it.doc);
    }
    p.pick_items.clearRetainingCapacity();
    const prompt = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(prompt);
    p.pick_prompt.clearRetainingCapacity();
    p.pick_prompt.appendSlice(gpa, prompt) catch {};
    p.pick_id = @intCast(args[2]);
}

fn hPickAdd(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const text = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    errdefer gpa.free(text);
    const doc = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch {
        gpa.free(text);
        return;
    };
    p.pick_items.append(gpa, .{ .text = text, .doc = doc }) catch {
        gpa.free(text);
        gpa.free(doc);
    };
}

fn hPickEnd(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const bp = gpa.create(WasmBoundPick) catch return;
    bp.* = .{ .plugin = p, .pick_id = p.pick_id };
    const entries = gpa.alloc(pick_mod.Entry, p.pick_items.items.len) catch {
        gpa.destroy(bp);
        return;
    };
    defer gpa.free(entries);
    for (p.pick_items.items, entries) |it, *e| e.* = .{ .text = it.text, .doc = it.doc };
    p.ctx.pick.open(p.ctx, p.pick_prompt.items, entries, .{
        .handler = wpPickAccept,
        .cleanup = wpPickCleanup,
        .data = bp,
    }) catch {
        gpa.destroy(bp);
    };
}

fn hOpenFilePick(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const prompt = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(prompt);
    const root = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(root);
    const bp = gpa.create(WasmBoundPick) catch return;
    bp.* = .{ .plugin = p, .pick_id = @intCast(args[4]) };
    const finder = fs_source.LocalFinder.create(gpa, p.ctx.buffers.pool, root) catch {
        gpa.destroy(bp);
        return;
    };
    // openWith closes the source on failure; only the BoundPick is ours.
    p.ctx.pick.openWith(p.ctx, prompt, &.{}, .{
        .handler = wpPickAccept,
        .cleanup = wpPickCleanup,
        .data = bp,
    }, .{ .source = finder.source(), .allow_free_text = true }) catch {
        gpa.destroy(bp);
    };
}

fn hPickChoice(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(caller.writeMemory(@intCast(args[0]), @intCast(args[1]), p.cur_choice) catch 0);
}

/// The add-order index of the accepted candidate (as the guest supplied them
/// via `pickAdd`), or -1 for free-text. Lets a source resolve the choice to a
/// position it recorded at add time, unambiguous under duplicate rows.
fn hPickChoiceIndex(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = if (p.ctx.pick.accepted_index) |i| @intCast(i) else -1;
}

/// Pick accept: stash the choice, dispatch to the guest's on_pick_accept.
fn wpPickAccept(ctx: *command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
    _ = ctx;
    const bp: *WasmBoundPick = @ptrCast(@alignCast(data.?));
    const p = bp.plugin;
    p.cur_choice = choice;
    defer p.cur_choice = &.{};
    try p.instance.callVoid("on_pick_accept", &.{@intCast(bp.pick_id)});
}

fn wpPickCleanup(data: ?*anyopaque, gpa: Allocator) void {
    const bp: *WasmBoundPick = @ptrCast(@alignCast(data.?));
    gpa.destroy(bp);
}

// Completion provider (host↔guest data-gather): the guest registers a
// provider in `init`; the host binds it into the caps registry with a
// trampoline that calls the guest's `on_complete` export per request, during
// which the guest pulls the prefix and pushes candidates back.
fn hProvideCompletion(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    // Cross-check: must be declared as the matching capability.
    if (!p.declaresCapability("edit/completion")) {
        p.load_error = error.UndeclaredCapability;
        return;
    }
    if (p.provider_id != null) return; // idempotent
    const gpa = p.gpa;
    const id = std.fmt.allocPrint(gpa, "plugin.{s}/edit/completion", .{p.name}) catch {
        p.load_error = error.OutOfMemory;
        return;
    };
    p.ctx.caps.register(.{
        .capability = "edit/completion",
        .id = id,
        .latency = .instant,
        .data = p,
        .handler = wpCompletionProvider,
    }) catch |e| {
        gpa.free(id);
        p.load_error = e;
        return;
    };
    p.provider_id = id;
}

fn hCompletionPrefix(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const n = caller.writeMemory(@intCast(args[0]), @intCast(args[1]), p.cur_prefix) catch 0;
    results[0] = @intCast(n);
}

fn hPushCompletion(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const out = p.completion_out orelse return;
    const gpa = p.gpa;
    const cand = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    // Dedup on collection (the in-process provider dedups too), so the
    // observable candidate set matches the Zig catalog plugin's.
    for (out.items) |w| if (std.mem.eql(u8, w, cand)) {
        gpa.free(cand);
        return;
    };
    out.append(gpa, cand) catch gpa.free(cand);
}

/// Caps trampoline: gather the guest's candidates for one request and push
/// them (the host deep-copies + re-stamps). Mirrors abi.zig's in-process
/// completionProvider — same shape, guest across the membrane.
fn wpCompletionProvider(data: ?*anyopaque, caps: *capability.Caps, req: *const capability.Request) anyerror!void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (req.kind != .completion) {
        caps.decline(req.session);
        return;
    }
    const gpa = p.gpa;
    var out: std.ArrayList([]const u8) = .empty;
    defer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    p.cur_prefix = req.text;
    p.completion_out = &out;
    defer {
        p.completion_out = null;
        p.cur_prefix = &.{};
    }
    p.instance.callVoid("on_complete", &.{}) catch {
        caps.decline(req.session);
        return;
    };
    var items: std.ArrayList(capability.CompletionItem) = .empty;
    defer items.deinit(gpa);
    for (out.items, 0..) |txt, i| {
        try items.append(gpa, .{ .text = @constCast(txt), .rank = @intCast(i) });
    }
    try caps.push(req.session, .{ .id = p.provider_id.?, .latency = .instant }, .{ .completion = items.items });
}

// Structural read (tree-sitter) + subbuffers.
fn hNodeAt(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const resolve = p.syntax_of orelse {
        results[0] = -1;
        return;
    };
    const syn = resolve(p.ctx.buffer()) orelse {
        results[0] = -1;
        return;
    };
    const node = syn.nodeAt(@intCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    const span = [2]u32{ @intCast(node.start), @intCast(node.end) };
    _ = caller.writeMemory(@intCast(args[3]), 8, std.mem.asBytes(&span)) catch {};
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), node.kind) catch 0);
}

/// The smallest NAMED node that STRICTLY encloses `[start, end)` — the
/// expand-selection primitive (call repeatedly to grow to the next scope).
/// Writes kind + [start,end] span; returns the kind length, or -1.
fn hNodeEnclosing(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const resolve = p.syntax_of orelse {
        results[0] = -1;
        return;
    };
    const syn = resolve(p.ctx.buffer()) orelse {
        results[0] = -1;
        return;
    };
    const start: usize = @intCast(args[0]);
    const end: usize = @intCast(args[1]);
    const anc = syn.ancestorsAt(p.gpa, start) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(anc);
    // Innermost first (reverse of root→leaf): the first node strictly bigger.
    var k = anc.len;
    while (k > 0) {
        k -= 1;
        const n = anc[k];
        if (n.start <= start and n.end >= end and !(n.start == start and n.end == end)) {
            const span = [2]u32{ @intCast(n.start), @intCast(n.end) };
            _ = caller.writeMemory(@intCast(args[4]), 8, std.mem.asBytes(&span)) catch {};
            results[0] = @intCast(caller.writeMemory(@intCast(args[2]), @intCast(args[3]), n.kind) catch 0);
            return;
        }
    }
    results[0] = -1;
}

/// Run a tree-sitter query (`scm`) over `[start, end)`; stash its captures on
/// the plugin (read back via `wl_query_capture`) and return the count, or -1.
fn hQuery(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.queryCapsClear();
    const resolve = p.syntax_of orelse {
        results[0] = -1;
        return;
    };
    const syn = resolve(p.ctx.buffer()) orelse {
        results[0] = -1;
        return;
    };
    const scm = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(scm);
    const caps = syn.queryCaptures(p.gpa, scm, .{ .start = @intCast(args[2]), .end = @intCast(args[3]) }) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(caps); // names transfer into query_caps below
    for (caps) |c| p.query_caps.append(p.gpa, .{ .name = c.name, .start = c.start, .end = c.end }) catch {
        p.gpa.free(c.name);
    };
    results[0] = @intCast(p.query_caps.items.len);
}

/// The named children of the smallest node at `off` (structural descent).
/// Materialized into the same capture buffer (kind as the "name"), read back
/// with `wl_query_capture`. Returns the child count, or -1.
fn hNodeChildren(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.queryCapsClear();
    const resolve = p.syntax_of orelse {
        results[0] = -1;
        return;
    };
    const syn = resolve(p.ctx.buffer()) orelse {
        results[0] = -1;
        return;
    };
    const kids = syn.childrenAt(p.gpa, @intCast(args[0])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(kids);
    for (kids) |k| {
        const name = p.gpa.dupe(u8, k.kind) catch continue;
        p.query_caps.append(p.gpa, .{ .name = name, .start = k.start, .end = k.end }) catch p.gpa.free(name);
    }
    results[0] = @intCast(p.query_caps.items.len);
}

/// Read the `i`-th capture from the last `wl_query`: writes name + [start,end]
/// span, returns the name length, or -1.
fn hQueryCapture(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const i: usize = @intCast(args[0]);
    if (i >= p.query_caps.items.len) {
        results[0] = -1;
        return;
    }
    const q = p.query_caps.items[i];
    const span = [2]u32{ @intCast(q.start), @intCast(q.end) };
    _ = caller.writeMemory(@intCast(args[3]), 8, std.mem.asBytes(&span)) catch {};
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), q.name) catch 0);
}

fn hClaimSubbuffer(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const subs = p.subbuffers orelse {
        results[0] = -1;
        return;
    };
    const ed = p.ctx.editor();
    const sub = subs.claim(p.gpa, &ed.doc, .{ .start = @intCast(args[0]), .end = @intCast(args[1]) }) catch {
        results[0] = -1;
        return;
    };
    p.subs.append(p.gpa, sub) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(p.subs.items.len - 1);
}

fn hSubbufferPutFact(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const handle: usize = @intCast(args[0]);
    if (handle >= p.subs.items.len) return;
    const gpa = p.gpa;
    const key = caller.readMemory(gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer gpa.free(key);
    const val = caller.readMemory(gpa, @intCast(args[3]), @intCast(args[4])) catch return;
    defer gpa.free(val);
    p.subs.items[handle].putFact(gpa, key, val) catch {};
}

/// Command dispatch back into the guest: stash the args (readable via
/// `wl_arg_*`), reset the result, run `on_command(id)`, and return whatever
/// result the guest set (`wl_set_result_*`, default nil). String results
/// borrow the plugin's `result_buf` until the next dispatch.
fn wpCmdTrampoline(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
    _ = ctx;
    const wc: *WasmCmd = @ptrCast(@alignCast(data.?));
    const p = wc.plugin;
    p.cur_args = args;
    p.result = .nil;
    p.stampsClear(); // fresh per-dispatch stamp table
    defer p.cur_args = &.{};
    try p.instance.callVoid("on_command", &.{@intCast(wc.id)});
    return p.result;
}
