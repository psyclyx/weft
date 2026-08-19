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
const surface_mod = @import("surface.zig");

// The shared leaf every handler group imports (WasmPlugin, perms, environ,
// the peer resolver). Re-exported below so `core.wasm_host.X` is unchanged.
const plugin = @import("wasm_host/plugin.zig");
pub const perm_fs_read = plugin.perm_fs_read;
pub const perm_fs_write = plugin.perm_fs_write;
pub const perm_net = plugin.perm_net;
pub const perm_proc = plugin.perm_proc;
pub const perm_timer = plugin.perm_timer;
pub const setEnviron = plugin.setEnviron;
pub const resolvePeerWp = plugin.resolvePeerWp;

const layers = @import("wasm_host/layers.zig");
pub const Flash = layers.Flash;
pub const flashState = layers.flashState;

const fs = @import("wasm_host/fs.zig");
pub const PeerFsBridge = fs.PeerFsBridge;
pub const setPeerFsBridge = fs.setPeerFsBridge;
pub const deliverToBuffer = fs.deliverToBuffer;

const proc_host = @import("wasm_host/proc.zig");

const activation = @import("wasm_host/activation.zig");
pub const notifyActivate = activation.notifyActivate;
const rooted_fs = @import("rooted_fs.zig");
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
    try d(linker, "wl_flash", 2, 0, layers.hFlash, p);
    // Styles feed: a plugin paints per-byte StyleClass over its (active) tool
    // buffer; the view renders it through Theme.styleColor (git/grep coloring).
    try d(linker, "wl_style_clear", 0, 0, layers.hStyleClear, p);
    try d(linker, "wl_style", 3, 0, layers.hStyle, p);
    try d(linker, "wl_fold_clear", 0, 0, layers.hFoldClear, p);
    try d(linker, "wl_fold", 2, 0, layers.hFold, p);
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
    // Read-only config data the config plane staged (weft.set), distinct store.
    try d(linker, "wl_config_get", 4, 1, hConfigGet, p);
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
    try d(linker, "wl_sticky_menu", 2, 0, hStickyMenu, p);
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
    // Menu bindings: enumerate the CURRENT menu mode's table (for which-key,
    // read by index during on_menu — no host allocation).
    try d(linker, "wl_menu_binding_count", 0, 1, hMenuBindingCount, p);
    try d(linker, "wl_menu_binding_key", 3, 1, hMenuBindingKey, p);
    try d(linker, "wl_menu_binding_cmd", 3, 1, hMenuBindingCmd, p);
    try d(linker, "wl_menu_binding_is_group", 1, 1, hMenuBindingIsGroup, p);
    // Surface (retained overlay: which-key/dired/magit render through this).
    try d(linker, "wl_surface_begin", 1, 0, hSurfaceBegin, p);
    try d(linker, "wl_surface_row", 0, 0, hSurfaceRow, p);
    try d(linker, "wl_surface_span", 3, 0, hSurfaceSpan, p);
    try d(linker, "wl_surface_end", 1, 0, hSurfaceEnd, p);
    try d(linker, "wl_surface_close", 0, 0, hSurfaceClose, p);
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
    // Activation (design §3): the path of the buffer taking focus.
    try d(linker, "wl_activate_path", 2, 1, activation.hActivatePath, p);
    try d(linker, "wl_claim_subbuffer", 2, 1, hClaimSubbuffer, p);
    try d(linker, "wl_subbuffer_put_fact", 5, 0, hSubbufferPutFact, p);
    // Effects (perm-gated): shell insert — the membrane form of editLater
    // with a host-side proc body (the guest can't run off-thread itself).
    try d(linker, "wl_shell_insert", 2, 0, proc_host.hShellInsert, p);
    // Interactive REPL sessions (design §6.3): a persistent child + comint.
    try d(linker, "wl_repl_start", 4, 1, hReplStart, p);
    try d(linker, "wl_repl_send", 3, 0, hReplSend, p);
    try d(linker, "wl_repl_quit", 1, 0, hReplQuit, p);
    // net.connect (design §4 Group D / §6.5): TCP or TLS, streamed to a buffer.
    try d(linker, "wl_net_connect", 6, 1, hNetConnect, p);
    try d(linker, "wl_net_send", 3, 0, hNetSend, p);
    try d(linker, "wl_net_close", 1, 0, hNetClose, p);
    try d(linker, "wl_proc_to_buffer", 4, 0, proc_host.hProcToBuffer, p);
    try d(linker, "wl_proc_append_buffer", 4, 0, proc_host.hProcAppendBuffer, p);
    try d(linker, "wl_proc_filter", 4, 0, proc_host.hProcFilter, p);
    // fs read/write (perm-gated) — design §4 Group B/C. Local, cwd-relative.
    try d(linker, "wl_fs_read", 4, 1, fs.hFsRead, p);
    try d(linker, "wl_fs_write", 4, 1, fs.hFsWrite, p);
    try d(linker, "wl_fs_append", 4, 1, fs.hFsAppend, p);
    try d(linker, "wl_fs_list", 6, 1, fs.hFsList, p);
    try d(linker, "wl_fs_list_async", 6, 1, fs.hFsListAsync, p);
}

const repl_session = @import("repl_session.zig");

/// Start a persistent REPL: `<cmd>` runs under /bin/sh, its output streaming
/// into the named comint buffer. Returns a session handle, or -1.
fn hReplStart(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!p.perms[perm_proc] or !p.perms[perm_timer]) {
        results[0] = -1;
        return;
    }
    const pool = p.pool orelse {
        results[0] = -1;
        return;
    };
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(cmd);
    const buf = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(buf);
    const s = repl_session.Session.start(gpa, pool, p.ctx, p.name, buf, &.{ "/bin/sh", "-c", cmd }, plugin.g_environ) catch {
        results[0] = -1;
        return;
    };
    p.sessions.append(gpa, s) catch {
        s.deinit();
        results[0] = -1;
        return;
    };
    results[0] = @intCast(p.sessions.items.len - 1);
}

/// Write a line to a REPL session's stdin.
fn hReplSend(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h: usize = @intCast(args[0]);
    if (h >= p.sessions.items.len) return;
    const s = p.sessions.items[h] orelse return;
    const line = caller.readMemory(p.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer p.gpa.free(line);
    s.send(line);
}

/// Quit a REPL session (kill + join); its handle stays valid but dead.
fn hReplQuit(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h: usize = @intCast(args[0]);
    if (h >= p.sessions.items.len) return;
    if (p.sessions.items[h]) |s| {
        s.deinit();
        p.sessions.items[h] = null;
    }
}

/// Frame-thread: drain every session's streamed output into its buffer.
/// Returns true if anything was written (the view repaints).
pub fn drainReplSessions(p: *WasmPlugin) bool {
    var any = false;
    for (p.sessions.items) |maybe| {
        if (maybe) |s| {
            if (s.drain()) any = true;
        }
    }
    for (p.net_sessions.items) |maybe| {
        if (maybe) |s| {
            if (s.drain()) any = true;
        }
    }
    return any;
}

const net_session = @import("net_session.zig");

/// net.connect (perm net): dial `host:port` — TLS verifying `sni` when non-empty
/// — streaming the socket into buffer `name`. Returns a handle, or -1.
fn hNetConnect(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!p.perms[perm_net]) {
        results[0] = -1;
        return;
    }
    const pool = p.pool orelse {
        results[0] = -1;
        return;
    };
    const gpa = p.gpa;
    const hostport = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(hostport);
    const name = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(name);
    const sni = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(sni);
    const s = net_session.Session.start(gpa, pool, p.ctx, p.name, name, hostport, if (sni.len > 0) sni else null) catch {
        results[0] = -1;
        return;
    };
    p.net_sessions.append(gpa, s) catch {
        s.deinit();
        results[0] = -1;
        return;
    };
    results[0] = @intCast(p.net_sessions.items.len - 1);
}

fn hNetSend(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h: usize = @intCast(args[0]);
    if (h >= p.net_sessions.items.len) return;
    const s = p.net_sessions.items[h] orelse return;
    const bytes = caller.readMemory(p.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer p.gpa.free(bytes);
    s.send(bytes);
}

fn hNetClose(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h: usize = @intCast(args[0]);
    if (h >= p.net_sessions.items.len) return;
    if (p.net_sessions.items[h]) |s| {
        s.deinit();
        p.net_sessions.items[h] = null;
    }
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
/// `wl_config_get(key_ptr, key_len, out_ptr, out_cap) → n` — read this plugin's
/// staged config value for `key` into guest memory, returning bytes written or
/// -1 if absent. Reads the DISTINCT config store (never runtime kv scratch).
/// The blob is the framed encoding the config shim produced (see guest
/// weft.configList); the guest decoder detects a short buffer.
fn hConfigGet(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const store = p.config_store orelse {
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
    // Guest-initiated: route through enterMode so entering a menu mode records
    // its one-shot return target. Host-side mode save/restore (the picker) uses
    // plain setMode and never records.
    p.ctx.keymap.enterMode(p.gpa, mode) catch {};
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

/// `sticky_menu(mode)`: mark a menu mode STICKY — it stays open after a leaf
/// key (flag-accumulating transients) instead of one-shot auto-popping.
fn hStickyMenu(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const mode = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(mode);
    p.ctx.keymap.markStickyMenu(p.gpa, mode) catch {};
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
// ── Menu bindings + on_menu: which-key (a guest) reads the current menu mode's
// table by index during its on_menu(open) and renders it into a surface. Core
// owns WHEN (fired at the frame boundary, top-level — see notifyMenu). ──
fn hMenuBindingCount(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(p.ctx.keymap.bindingCount(p.ctx.keymap.currentMode()));
}
fn hMenuBindingKey(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const km = p.ctx.keymap;
    const b = km.bindingAt(km.currentMode(), @intCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), b.key) catch 0);
}
fn hMenuBindingCmd(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const km = p.ctx.keymap;
    const b = km.bindingAt(km.currentMode(), @intCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), b.command) catch 0);
}

/// Whether the `i`-th binding is a GROUP (opens a submenu) rather than a leaf
/// command. Convention (see vim): a submenu-entry binds a key to a command
/// named the same as the menu mode it enters — so a binding is a group exactly
/// when its command is itself a registered menu mode. No bind-ABI change needed.
fn hMenuBindingIsGroup(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const km = p.ctx.keymap;
    const b = km.bindingAt(km.currentMode(), @intCast(args[0])) orelse {
        results[0] = 0;
        return;
    };
    results[0] = if (km.isMenuMode(b.command)) 1 else 0;
}

/// Fire a guest's `on_menu(open)` — a menu mode was entered (open=1) or left
/// (open=0). Called at the FRAME boundary (top-level, never nested inside
/// another guest call), so a menu-owner plugin re-entering its own wasmtime
/// store is impossible. Guests without the export are skipped.
pub fn notifyMenu(p: *WasmPlugin, open: bool) void {
    p.instance.callVoid("on_menu", &.{@as(i32, if (open) 1 else 0)}) catch {};
}

// ── Surface membrane: a guest builds its retained overlay begin→row→span→end,
// then the view draws it every frame until close. Mirrors the pick membrane. ──
fn hSurfaceBegin(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const placement: surface_mod.Placement = switch (@as(u32, @bitCast(args[0]))) {
        1 => .corner,
        2 => .center,
        else => .bottom,
    };
    p.surface.begin(p.gpa, placement);
}
fn hSurfaceRow(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.surface.addRow(p.gpa);
}
fn hSurfaceSpan(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const text = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(text);
    p.surface.addSpan(p.gpa, text, surface_mod.Role.fromInt(@bitCast(args[2])));
}
fn hSurfaceEnd(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const selected: ?usize = if (args[0] < 0) null else @intCast(args[0]);
    p.surface.end(p.gpa, selected);
}
fn hSurfaceClose(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.surface.close(p.gpa);
}

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
