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

const sessions = @import("wasm_host/sessions.zig");
pub const drainReplSessions = sessions.drainReplSessions;

const syntax_host = @import("wasm_host/syntax.zig");
const capability_host = @import("wasm_host/capability.zig");
const pick_host = @import("wasm_host/pick.zig");
const surface_host = @import("wasm_host/surface.zig");
const menu = @import("wasm_host/menu.zig");
pub const notifyMenu = menu.notifyMenu;
const buffers_host = @import("wasm_host/buffers.zig");
const declare = @import("wasm_host/declare.zig");
const config_kv = @import("wasm_host/config_kv.zig");
const dispatch = @import("wasm_host/dispatch.zig");
const keymap = @import("wasm_host/keymap.zig");
const commands = @import("wasm_host/commands.zig");
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
    try d(linker, "wl_log", 3, 0, declare.hLog, p);
    // Describe phase: declarations.
    try d(linker, "wl_declare_command", 2, 0, declare.hDeclareCommand, p);
    try d(linker, "wl_declare_capability", 2, 0, declare.hDeclareCapability, p);
    try d(linker, "wl_request_perm", 1, 0, declare.hRequestPerm, p);
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
    try d(linker, "wl_register", 2, 1, commands.hRegister, p);
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
    try d(linker, "wl_kv_get", 4, 1, config_kv.hKvGet, p);
    try d(linker, "wl_kv_put", 4, 0, config_kv.hKvPut, p);
    // Read-only config data the config plane staged (weft.set), distinct store.
    try d(linker, "wl_config_get", 4, 1, config_kv.hConfigGet, p);
    // Config surface.
    try d(linker, "wl_echo", 2, 0, dispatch.hEcho, p);
    // Command args in + result out (during on_command).
    try d(linker, "wl_arg_count", 0, 1, dispatch.hArgCount, p);
    try d(linker, "wl_arg_int", 1, 1, dispatch.hArgInt, p);
    try d(linker, "wl_arg_str", 3, 1, dispatch.hArgStr, p);
    try d(linker, "wl_set_result_int", 1, 0, dispatch.hSetResultInt, p);
    try d(linker, "wl_set_result_str", 2, 0, dispatch.hSetResultStr, p);
    // Config surface (the local plane).
    try d(linker, "wl_bind_key", 6, 0, keymap.hBindKey, p);
    try d(linker, "wl_set_mode", 2, 0, keymap.hSetMode, p);
    try d(linker, "wl_set_fallback", 4, 0, keymap.hSetFallback, p);
    try d(linker, "wl_text_input", 5, 0, keymap.hTextInput, p);
    try d(linker, "wl_menu_mode", 2, 0, keymap.hMenuMode, p);
    try d(linker, "wl_sticky_menu", 2, 0, keymap.hStickyMenu, p);
    try d(linker, "wl_run", 2, 0, commands.hRun, p);
    try d(linker, "wl_run_int", 3, 0, commands.hRunInt, p);
    try d(linker, "wl_run_str", 4, 0, commands.hRunStr, p);
    try d(linker, "wl_run_str2", 6, 0, commands.hRunStr2, p);
    // Introspection.
    try d(linker, "wl_command_count", 0, 1, commands.hCommandCount, p);
    try d(linker, "wl_command_name", 3, 1, commands.hCommandName, p);
    try d(linker, "wl_command_summary", 3, 1, commands.hCommandSummary, p);
    try d(linker, "wl_buffer_count", 0, 1, buffers_host.hBufferCount, p);
    try d(linker, "wl_buffer_id", 1, 1, buffers_host.hBufferId, p);
    try d(linker, "wl_buffer_name", 3, 1, buffers_host.hBufferName, p);
    try d(linker, "wl_buffer_active", 1, 1, buffers_host.hBufferActive, p);
    try d(linker, "wl_buffer_readonly", 1, 1, buffers_host.hBufferReadonly, p);
    // Pick.
    try d(linker, "wl_pick_begin", 3, 0, pick_host.hPickBegin, p);
    try d(linker, "wl_pick_add", 4, 0, pick_host.hPickAdd, p);
    try d(linker, "wl_pick_end", 0, 0, pick_host.hPickEnd, p);
    try d(linker, "wl_open_file_pick", 5, 0, pick_host.hOpenFilePick, p);
    try d(linker, "wl_pick_choice", 2, 1, pick_host.hPickChoice, p);
    try d(linker, "wl_pick_choice_index", 0, 1, pick_host.hPickChoiceIndex, p);
    // Menu bindings: enumerate the CURRENT menu mode's table (for which-key,
    // read by index during on_menu — no host allocation).
    try d(linker, "wl_menu_binding_count", 0, 1, menu.hMenuBindingCount, p);
    try d(linker, "wl_menu_binding_key", 3, 1, menu.hMenuBindingKey, p);
    try d(linker, "wl_menu_binding_cmd", 3, 1, menu.hMenuBindingCmd, p);
    try d(linker, "wl_menu_binding_is_group", 1, 1, menu.hMenuBindingIsGroup, p);
    // Surface (retained overlay: which-key/dired/magit render through this).
    try d(linker, "wl_surface_begin", 1, 0, surface_host.hSurfaceBegin, p);
    try d(linker, "wl_surface_row", 0, 0, surface_host.hSurfaceRow, p);
    try d(linker, "wl_surface_span", 3, 0, surface_host.hSurfaceSpan, p);
    try d(linker, "wl_surface_end", 1, 0, surface_host.hSurfaceEnd, p);
    try d(linker, "wl_surface_close", 0, 0, surface_host.hSurfaceClose, p);
    // Completion provider (host↔guest data-gather).
    try d(linker, "wl_provide_completion", 0, 0, capability_host.hProvideCompletion, p);
    try d(linker, "wl_completion_prefix", 2, 1, capability_host.hCompletionPrefix, p);
    try d(linker, "wl_push_completion", 2, 0, capability_host.hPushCompletion, p);
    // Structural read + subbuffers.
    try d(linker, "wl_node_at", 4, 1, syntax_host.hNodeAt, p);
    // syntax.query (design §4): the tree stays host-side; captures/nodes cross.
    try d(linker, "wl_node_enclosing", 5, 1, syntax_host.hNodeEnclosing, p);
    try d(linker, "wl_query", 4, 1, syntax_host.hQuery, p);
    try d(linker, "wl_query_capture", 4, 1, syntax_host.hQueryCapture, p);
    try d(linker, "wl_node_children", 1, 1, syntax_host.hNodeChildren, p);
    // Activation (design §3): the path of the buffer taking focus.
    try d(linker, "wl_activate_path", 2, 1, activation.hActivatePath, p);
    try d(linker, "wl_claim_subbuffer", 2, 1, syntax_host.hClaimSubbuffer, p);
    try d(linker, "wl_subbuffer_put_fact", 5, 0, syntax_host.hSubbufferPutFact, p);
    // Effects (perm-gated): shell insert — the membrane form of editLater
    // with a host-side proc body (the guest can't run off-thread itself).
    try d(linker, "wl_shell_insert", 2, 0, proc_host.hShellInsert, p);
    // Interactive REPL sessions (design §6.3): a persistent child + comint.
    try d(linker, "wl_repl_start", 4, 1, sessions.hReplStart, p);
    try d(linker, "wl_repl_send", 3, 0, sessions.hReplSend, p);
    try d(linker, "wl_repl_quit", 1, 0, sessions.hReplQuit, p);
    // net.connect (design §4 Group D / §6.5): TCP or TLS, streamed to a buffer.
    try d(linker, "wl_net_connect", 6, 1, sessions.hNetConnect, p);
    try d(linker, "wl_net_send", 3, 0, sessions.hNetSend, p);
    try d(linker, "wl_net_close", 1, 0, sessions.hNetClose, p);
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

// ── Host import table: one small function per abi.Abi method ──────────

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
