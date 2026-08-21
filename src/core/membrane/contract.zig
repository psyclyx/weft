//! core/membrane/contract.zig — the one comptime table describing the
//! `weft.*` guest↔host import membrane, the other half of which is hand-
//! mirrored in src/guest/weft.zig's `extern "weft"` block. Today this table
//! drives the HOST side: `wasm_host.defineImports` walks it to bind every
//! `wl_*` import onto the wasmtime Linker, instead of the (name, nparams,
//! nresults, handler) four-tuples wasm_host.zig used to hand-copy one at a
//! time. One source of truth kills the class of bug where a guest extern's
//! arity drifts from its host import's arity because someone edited one side
//! and forgot the other.
//!
//! Scope (doc/north-star-plan.md §2.5 + §6, task W0a-C — deliberately
//! narrow): this table is the HOST import side only. It does NOT (yet)
//! generate the guest externs in src/guest/weft.zig, the ~10 host→guest
//! exported entrypoints (today MissingExport-tolerant by hand), or quickjs's
//! `qjs_*` table — those are the follow-up W0a slices. The `ValType`/`Perm`/
//! `doc` fields exist so that follow-up can walk THIS table rather than
//! inventing a second one; `params`/`results` are typed as `[]const ValType`
//! (not a bare count) for the same reason — today every value is `.i32`, but
//! a guest-side generator needs the type, not just the arity. (It will also
//! need per-param SIGNEDNESS — the guest externs mix u32/i32 — which this
//! table does not yet carry; that lands with the generator, not before.)
//!
//! Not in scope: marshalling, scratch buffers, or handler bodies — those stay
//! exactly where they are (wasm_host/*.zig), unchanged.

const std = @import("std");
const wasm = @import("../wasm.zig");
const HostFn = wasm.Linker.HostFn;

const activation = @import("../wasm_host/activation.zig");
const buffers = @import("../wasm_host/buffers.zig");
const capability = @import("../wasm_host/capability.zig");
const commands = @import("../wasm_host/commands.zig");
const config_kv = @import("../wasm_host/config_kv.zig");
const declare = @import("../wasm_host/declare.zig");
const dispatch = @import("../wasm_host/dispatch.zig");
const edit = @import("../wasm_host/edit.zig");
const fs = @import("../wasm_host/fs.zig");
const keymap = @import("../wasm_host/keymap.zig");
const layers = @import("../wasm_host/layers.zig");
const menu = @import("../wasm_host/menu.zig");
const pick = @import("../wasm_host/pick.zig");
const proc = @import("../wasm_host/proc.zig");
const register = @import("../wasm_host/register.zig");
const sessions = @import("../wasm_host/sessions.zig");
const surface = @import("../wasm_host/surface.zig");
const syntax = @import("../wasm_host/syntax.zig");
const tool = @import("../wasm_host/tool.zig");

/// The wasm value type crossing the membrane. Every `wl_*` import is i32-only
/// today (scalars + opaque handles; bulk data crosses as a `(ptr, len)` i32
/// pair into the guest's linear memory) — typed as an enum rather than
/// hardcoded, so a future value shape (externref, i64) is expressible without
/// reshaping the table, not because one is coming.
pub const ValType = enum { i32 };

/// Which `wasm_host/*.zig` module owns an entry's handler. Also the table's
/// sort key: entries below are grouped contiguously (not call-historical
/// order) so a reviewer can see one module's whole surface at a glance.
pub const Group = enum {
    declare,
    edit,
    layers,
    config_kv,
    dispatch,
    keymap,
    commands,
    buffers,
    pick,
    menu,
    surface,
    capability,
    syntax,
    activation,
    tool,
    register,
    proc,
    sessions,
    fs,
};

/// The permission gate an entry's handler checks (`WasmPlugin.perms[..]`)
/// before doing anything effectful. `null` = ungated today — most of the
/// table; the north star names "grant story vs 5 booleans" (C9) and trap-on-
/// deny as unchanged in W0a, so this field documents today's real gates, it
/// doesn't add new ones. `proc_timer` names the one recurring COMBINATION
/// this codebase actually checks: every `perm_timer` check in wasm_host/
/// proc.zig and sessions.zig is paired with `perm_proc`, and `timer` never
/// gates alone — modeled honestly as the pair it always is, rather than
/// bolting on a multi-perm field for a case that doesn't otherwise exist.
pub const Perm = enum { fs_read, fs_write, net, proc, proc_timer };

pub const Entry = struct {
    /// The `weft.<name>` import name — matches the guest's `extern "weft" fn
    /// <name>(..)` in src/guest/weft.zig exactly.
    name: []const u8,
    params: []const ValType,
    results: []const ValType,
    group: Group,
    handler: HostFn,
    perm: ?Perm = null,
    /// One-line human doc — NOT the source of truth for behavior (the
    /// handler body is), just review/generation context.
    doc: []const u8,
};

fn words(comptime n: usize) []const ValType {
    comptime var arr: [n]ValType = @splat(.i32);
    return &arr;
}

fn e(name: []const u8, comptime np: usize, comptime nr: usize, group: Group, handler: HostFn, doc: []const u8) Entry {
    return .{ .name = name, .params = words(np), .results = words(nr), .group = group, .handler = handler, .doc = doc };
}

fn eg(name: []const u8, comptime np: usize, comptime nr: usize, group: Group, handler: HostFn, perm: Perm, doc: []const u8) Entry {
    return .{ .name = name, .params = words(np), .results = words(nr), .group = group, .handler = handler, .perm = perm, .doc = doc };
}

/// The membrane's host-import table: one entry per `weft.wl_*` import the
/// guest shim declares. `wasm_host.defineImports` walks this to bind the
/// Linker — nothing else in the host tree defines a `weft.*` import; add or
/// change one here, and only here (then mirror it by hand in
/// src/guest/weft.zig until the follow-up task generates that side too).
pub const imports = [_]Entry{
    // ── declare.zig — describe-phase declarations ──────────────────────
    e("wl_log", 3, 0, .declare, declare.hLog, "write a guest log line at `level`"),
    e("wl_declare_command", 2, 0, .declare, declare.hDeclareCommand, "describe-phase: declare a command name (id assigned on first declare)"),
    e("wl_declare_capability", 2, 0, .declare, declare.hDeclareCapability, "describe-phase: declare an abstract capability name this plugin provides"),
    e("wl_request_perm", 1, 0, .declare, declare.hRequestPerm, "describe-phase: request a permission bit (fs_read/fs_write/net/proc/timer)"),

    // ── edit.zig — read-only, native editor step, write, stamped ranges ─
    e("wl_cursor", 0, 1, .edit, edit.hCursor, "the cursor's byte offset in the active document"),
    e("wl_byte_len", 0, 1, .edit, edit.hByteLen, "the active document's byte length"),
    e("wl_doc_revision", 0, 1, .edit, edit.hDocRevision, "the active document's monotonic commit count (a cheap change token)"),
    e("wl_slice", 4, 1, .edit, edit.hSlice, "copy `[start,end)` of the active document into guest memory"),
    e("wl_line_at", 2, 0, .edit, edit.hLineAt, "write the `[start,end)` byte span of the line containing `offset`"),
    e("wl_selection", 1, 1, .edit, edit.hSelection, "the active selection's other endpoint (mark), or the cursor if none"),
    e("wl_path", 2, 1, .edit, edit.hPath, "the active buffer's path into guest memory, or -1 if unnamed"),
    e("wl_editor_step", 3, 1, .edit, edit.hEditorStep, "the pure step primitive a motion composes (char boundary or line motion); no cursor move"),
    e("wl_set_selection", 2, 0, .edit, edit.hSetSelection, "select `[start,end)` (mark at start, cursor at end)"),
    e("wl_edit", 4, 0, .edit, edit.hEdit, "the gated edit door: replace `[start,end)` with bytes, authored as the plugin's own peer"),
    e("wl_render", 4, 0, .edit, edit.hRender, "produce derived/streamed content into a buffer, bypassing read-only (output, not user text)"),
    e("wl_edit_as", 6, 0, .edit, edit.hEditAs, "like `wl_edit` but authored as a named `.agent` sub-peer (its own selective-undo unit)"),
    e("wl_jump", 1, 0, .edit, edit.hJump, "move the cursor to `offset`"),
    e("wl_stamp_range", 2, 1, .edit, edit.hStampRange, "stamp `[start,end)` at the current doc version into this plugin's range table; -1 on failure"),
    e("wl_set_result_range", 1, 0, .edit, edit.hSetResultRange, "set the command result to a `range` Value from a stamped handle"),
    e("wl_run_range", 2, 1, .edit, edit.hRunRange, "run a command by name, rebase + re-stamp its returned range (await-a-motion)"),
    e("wl_range_ends", 2, 1, .edit, edit.hRangeEnds, "resolve a stamped-range handle to its current `[start,end)`"),
    e("wl_run_range_arg", 3, 0, .edit, edit.hRunRangeArg, "run a command passing a stamped range (by handle) as its single arg"),
    e("wl_arg_range", 1, 1, .edit, edit.hArgRange, "read a `range` command arg: rebase to head, re-stamp into this plugin's table"),
    e("wl_edit_range", 3, 0, .edit, edit.hEditRange, "apply an edit over a stamped-range handle through the gated edit door"),

    // ── layers.zig — flash/style/fold/readonly/decorate/breakpoints ────
    e("wl_flash", 2, 0, .layers, layers.hFlash, "vim-goggles: flash `[start,end)` for the frame loop to fade and the view to draw"),
    e("wl_style_clear", 0, 0, .layers, layers.hStyleClear, "(re)claim the active buffer's styles layer and baseline it to `.normal`"),
    e("wl_style", 3, 0, .layers, layers.hStyle, "paint `[start,end)` of the active buffer's styles bulk with `class`"),
    e("wl_fold_clear", 0, 0, .layers, layers.hFoldClear, "(re)claim the active buffer's fold layer and empty it"),
    e("wl_fold", 2, 0, .layers, layers.hFold, "hide `[start,end)` as an invisible/folded span"),
    e("wl_readonly_clear", 0, 0, .layers, layers.hReadOnlyClear, "(re)claim the active buffer's read-only-span layer and empty it"),
    e("wl_readonly_span", 2, 0, .layers, layers.hReadOnlySpan, "mark `[start,end)` read-only (edit-door defense in depth)"),
    e("wl_decorate_clear", 0, 0, .layers, layers.hDecorateClear, "(re)claim the active buffer's decorations layer and empty it"),
    e("wl_decorate", 5, 0, .layers, layers.hDecorate, "place a display-only decoration (virtual text) anchored at `anchor`"),
    e("wl_breakpoint_publish", 4, 0, .layers, layers.hBreakpointPublish, "publish a file's breakpoint lines to the process-global registry (for DAP)"),

    // ── config_kv.zig — runtime kv scratch + the distinct config store ──
    e("wl_kv_get", 4, 1, .config_kv, config_kv.hKvGet, "read this plugin's runtime kv scratch value for `key`"),
    e("wl_kv_put", 4, 0, .config_kv, config_kv.hKvPut, "write this plugin's runtime kv scratch value for `key`"),
    e("wl_config_get", 4, 1, .config_kv, config_kv.hConfigGet, "read this plugin's staged config value (the distinct weft.set store)"),

    // ── dispatch.zig — echo + command args in/result out ───────────────
    e("wl_echo", 2, 0, .dispatch, dispatch.hEcho, "print a message to the echo area"),
    e("wl_arg_count", 0, 1, .dispatch, dispatch.hArgCount, "the current command dispatch's argument count"),
    e("wl_arg_int", 1, 1, .dispatch, dispatch.hArgInt, "the `i`-th dispatch arg as an int"),
    e("wl_arg_str", 3, 1, .dispatch, dispatch.hArgStr, "the `i`-th dispatch arg as a string, into guest memory"),
    e("wl_set_result_int", 1, 0, .dispatch, dispatch.hSetResultInt, "set the command result to an int"),
    e("wl_set_result_str", 2, 0, .dispatch, dispatch.hSetResultStr, "set the command result to a string"),

    // ── keymap.zig — the local config plane: bindings/modes/providers ──
    e("wl_bind_key", 6, 0, .keymap, keymap.hBindKey, "bind a key chord in mode `m` to command `c`"),
    e("wl_set_mode", 2, 0, .keymap, keymap.hSetMode, "switch the active buffer's mode"),
    e("wl_set_fallback", 4, 0, .keymap, keymap.hSetFallback, "declare mode `m`'s fallback (parent) mode for unbound keys"),
    e("wl_text_input", 5, 0, .keymap, keymap.hTextInput, "declare mode `m`'s text-input command (and whether it takes the typed char)"),
    e("wl_menu_mode", 2, 0, .keymap, keymap.hMenuMode, "declare a mode a which-key-style menu"),
    e("wl_locked_mode", 2, 0, .keymap, keymap.hLockedMode, "mark a read-only projection mode pinned (can't leave for a generic editing mode)"),
    e("wl_resting_mode", 2, 0, .keymap, keymap.hRestingMode, "declare a mode a buffer can rest in (`baseMode` stops there)"),
    e("wl_exit_to_resting", 0, 0, .keymap, keymap.hExitToResting, "leave a transient mode back to the active buffer's resting mode"),
    e("wl_sticky_menu", 2, 0, .keymap, keymap.hStickyMenu, "mark a menu mode sticky (stays open after a leaf key)"),
    e("wl_declare_action", 2, 0, .keymap, keymap.hDeclareAction, "declare an abstract action + its trampoline command"),
    e("wl_provide", 11, 0, .keymap, keymap.hProvide, "register a provider for an action, scoped by mode/lang/tool + priority"),

    // ── commands.zig — register/run/introspect ──────────────────────────
    e("wl_register", 2, 1, .commands, commands.hRegister, "register-phase: intern a name into this plugin's local command id table"),
    e("wl_run", 2, 0, .commands, commands.hRun, "run a command by name, no args"),
    e("wl_run_int", 3, 0, .commands, commands.hRunInt, "run a command by name with one int arg"),
    e("wl_run_str", 4, 0, .commands, commands.hRunStr, "run a command by name with one string arg"),
    e("wl_run_str2", 6, 0, .commands, commands.hRunStr2, "run a command by name with two string args"),
    e("wl_command_count", 0, 1, .commands, commands.hCommandCount, "the number of registered commands (introspection)"),
    e("wl_command_name", 3, 1, .commands, commands.hCommandName, "the `i`-th command's name, into guest memory"),
    e("wl_command_summary", 3, 1, .commands, commands.hCommandSummary, "the `i`-th command's one-line summary, into guest memory"),

    // ── buffers.zig — the open-buffer list (introspection) ──────────────
    e("wl_buffer_count", 0, 1, .buffers, buffers.hBufferCount, "the number of open buffers"),
    e("wl_buffer_id", 1, 1, .buffers, buffers.hBufferId, "the `i`-th open buffer's id, or -1"),
    e("wl_buffer_name", 3, 1, .buffers, buffers.hBufferName, "the `i`-th open buffer's name, into guest memory"),
    e("wl_buffer_active", 1, 1, .buffers, buffers.hBufferActive, "whether the `i`-th buffer is the active one"),
    e("wl_buffer_readonly", 1, 1, .buffers, buffers.hBufferReadonly, "whether the `i`-th buffer is read-only"),

    // ── pick.zig — fuzzy pick build/open/accept ─────────────────────────
    e("wl_pick_begin", 3, 0, .pick, pick.hPickBegin, "start building a fuzzy pick with `prompt`, tagged `pick_id`"),
    e("wl_pick_add", 4, 0, .pick, pick.hPickAdd, "add a candidate (text, detail) to the pick being built"),
    e("wl_pick_end", 0, 0, .pick, pick.hPickEnd, "open the pick built so far"),
    e("wl_open_file_pick", 5, 0, .pick, pick.hOpenFilePick, "open a file-tree pick rooted at `root`"),
    e("wl_pick_choice", 2, 1, .pick, pick.hPickChoice, "the accepted pick's text, into guest memory"),
    e("wl_pick_choice_index", 0, 1, .pick, pick.hPickChoiceIndex, "the accepted candidate's add-order index, or -1 for free-text"),

    // ── menu.zig — which-key style menu-mode binding introspection ─────
    e("wl_menu_binding_count", 0, 1, .menu, menu.hMenuBindingCount, "the current menu mode's binding-table entry count"),
    e("wl_menu_binding_key", 3, 1, .menu, menu.hMenuBindingKey, "the `i`-th menu binding's key chord, into guest memory"),
    e("wl_menu_binding_cmd", 3, 1, .menu, menu.hMenuBindingCmd, "the `i`-th menu binding's command name, into guest memory"),
    e("wl_menu_binding_is_group", 1, 1, .menu, menu.hMenuBindingIsGroup, "whether the `i`-th menu binding is a group (submenu), not a leaf"),

    // ── surface.zig — the retained overlay (which-key/dired/magit) ─────
    e("wl_surface_begin", 1, 0, .surface, surface.hSurfaceBegin, "open a retained overlay surface at `placement`"),
    e("wl_surface_row", 0, 0, .surface, surface.hSurfaceRow, "start a new row in the open surface"),
    e("wl_surface_span", 3, 0, .surface, surface.hSurfaceSpan, "append a styled text span to the current surface row"),
    e("wl_surface_end", 1, 0, .surface, surface.hSurfaceEnd, "close the open surface, marking a row selected or not"),
    e("wl_surface_close", 0, 0, .surface, surface.hSurfaceClose, "close the surface without a selection"),

    // ── capability.zig — the completion provider gather/push ───────────
    e("wl_provide_completion", 0, 0, .capability, capability.hProvideCompletion, "caps trampoline: hand the guest the pending completion session"),
    e("wl_completion_prefix", 2, 1, .capability, capability.hCompletionPrefix, "the current completion prefix, into guest memory"),
    e("wl_caps_item", 11, 0, .capability, capability.hCapsItem, "append one rich completion item to the plugin's pending batch"),
    e("wl_caps_commit", 1, 0, .capability, capability.hCapsCommit, "flush the pending completion batch into the session"),
    e("wl_caps_decline", 1, 0, .capability, capability.hCapsDecline, "decline to answer a completion session"),

    // ── syntax.zig — structural (tree-sitter) read + subbuffers ────────
    e("wl_node_at", 4, 1, .syntax, syntax.hNodeAt, "the smallest named tree-sitter node covering `offset`"),
    e("wl_node_enclosing", 5, 1, .syntax, syntax.hNodeEnclosing, "the smallest named node strictly enclosing `[start,end)` (expand-selection)"),
    e("wl_query", 4, 1, .syntax, syntax.hQuery, "run a tree-sitter query over `[start,end)`, stashing its captures"),
    e("wl_query_capture", 4, 1, .syntax, syntax.hQueryCapture, "read the `i`-th capture from the last `wl_query`/`wl_node_children`"),
    e("wl_node_children", 1, 1, .syntax, syntax.hNodeChildren, "the named children of the smallest node at `off` (structural descent)"),
    e("wl_claim_subbuffer", 2, 1, .syntax, syntax.hClaimSubbuffer, "claim `[start,end)` as a subbuffer (a projection row's hidden identity)"),
    e("wl_subbuffer_put_fact", 5, 0, .syntax, syntax.hSubbufferPutFact, "attach a key/value fact to a claimed subbuffer"),
    e("wl_subbuffer_clear", 0, 0, .syntax, syntax.hSubbufferClear, "release every subbuffer this plugin claimed"),
    e("wl_subbuffer_fact_at", 5, 1, .syntax, syntax.hSubbufferFactAt, "read fact `key` off the innermost subbuffer covering `offset`"),

    // ── activation.zig — the focus event ────────────────────────────────
    e("wl_activate_path", 2, 1, .activation, activation.hActivatePath, "the path of the buffer taking focus (host→guest activation, borrowed)"),

    // ── tool.zig — projection ownership ─────────────────────────────────
    e("wl_tool_backing", 2, 0, .tool, tool.hToolBacking, "mark the active buffer as this plugin's tool projection"),

    // ── register.zig — the editor-agnostic yank/paste service ──────────
    e("wl_yank_range", 3, 0, .register, register.hYankRange, "capture `[start,end)` into the register, snapshotting overlapping subbuffer facts"),
    e("wl_register_text", 2, 1, .register, register.hRegisterText, "the register's bytes, into guest memory"),
    e("wl_register_linewise", 0, 1, .register, register.hRegisterLinewise, "whether the register holds a linewise yank"),
    e("wl_paste_at", 1, 0, .register, register.hPasteAt, "re-claim a subbuffer for each ferried payload pasted at `base`"),

    // ── proc.zig — perm-gated off-thread process effects ───────────────
    eg("wl_shell_insert", 2, 0, .proc, proc.hShellInsert, .proc_timer, "run `<cmd>` off-thread and insert its stdout at the cursor when done"),
    eg("wl_proc_spawn", 2, 1, .proc, proc.hProcSpawn, .proc, "spawn a persistent subprocess; its stdout buffers for `wl_proc_read`"),
    e("wl_proc_send", 3, 0, .proc, proc.hProcSend, "write to a spawned subprocess's stdin"),
    e("wl_proc_read", 3, 1, .proc, proc.hProcRead, "drain buffered stdout from a spawned subprocess"),
    e("wl_proc_close", 1, 0, .proc, proc.hProcClose, "kill a spawned subprocess (slot stays for handle stability)"),
    e("wl_cwd", 2, 1, .proc, proc.hCwd, "the process working directory (for absolute `file://` uris)"),
    eg("wl_proc_to_buffer", 4, 0, .proc, proc.hProcToBuffer, .proc_timer, "run `<cmd>` off-thread and replace a named scratch buffer with its stdout"),
    eg("wl_proc_append_buffer", 4, 0, .proc, proc.hProcAppendBuffer, .proc_timer, "like `wl_proc_to_buffer` but appends (a console log) instead of replacing"),
    eg("wl_proc_filter", 4, 0, .proc, proc.hProcFilter, .proc_timer, "filter `[start,end)` through `<cmd>` in place (formatters)"),

    // ── sessions.zig — persistent streamed REPL + net sessions ─────────
    eg("wl_repl_start", 4, 1, .sessions, sessions.hReplStart, .proc_timer, "start a persistent REPL streaming into a named comint buffer"),
    e("wl_repl_send", 3, 0, .sessions, sessions.hReplSend, "write a line to a REPL session's stdin"),
    e("wl_repl_quit", 1, 0, .sessions, sessions.hReplQuit, "quit a REPL session (kill+join; handle stays valid but dead)"),
    eg("wl_net_connect", 6, 1, .sessions, sessions.hNetConnect, .net, "dial `host:port` (TCP/TLS), streaming into a named buffer"),
    e("wl_net_send", 3, 0, .sessions, sessions.hNetSend, "write bytes to a connected net session"),
    e("wl_net_close", 1, 0, .sessions, sessions.hNetClose, "close a net session"),

    // ── fs.zig — perm-gated local filesystem doors ─────────────────────
    eg("wl_fs_read", 4, 1, .fs, fs.hFsRead, .fs_read, "read a file into the guest"),
    eg("wl_fs_exists", 2, 1, .fs, fs.hFsExists, .fs_read, "what a cwd-relative path is (absent/file/dir/other), without reading it"),
    eg("wl_fs_write", 4, 1, .fs, fs.hFsWrite, .fs_write, "replace a file's contents"),
    eg("wl_fs_append", 4, 1, .fs, fs.hFsAppend, .fs_write, "append to a file (capture)"),
    eg("wl_fs_list", 6, 1, .fs, fs.hFsList, .fs_read, "list a local directory (locus-routed; remote authorities degrade to -1)"),
    eg("wl_fs_list_async", 6, 1, .fs, fs.hFsListAsync, .fs_read, "queue an async `.peer` directory listing, delivered to a buffer"),
};

/// The table's size, alongside `imports.len`, as a deliberate tripwire: bump
/// this BY HAND alongside adding or removing a contract entry (and its guest
/// extern in src/guest/weft.zig), so an accidental add/remove — a merge
/// conflict, a copy-paste slip, a half-finished edit — fails the build with a
/// pointed message instead of silently drifting the two ~123-entry tables
/// apart again (the exact class this table exists to kill).
const expected_count = 123;

comptime {
    @setEvalBranchQuota(50_000); // the O(n²) duplicate-name scan below, n≈123
    if (imports.len != expected_count) @compileError(std.fmt.comptimePrint(
        "core/membrane/contract.zig: imports table has {d} entries, expected {d}. " ++
            "If you added or removed a wl_* host import, update `expected_count` here " ++
            "AND mirror the change by hand in src/guest/weft.zig's extern block.",
        .{ imports.len, expected_count },
    ));
    for (imports, 0..) |a, i| {
        if (!std.mem.startsWith(u8, a.name, "wl_"))
            @compileError("core/membrane/contract.zig: '" ++ a.name ++ "' doesn't look like a wl_* import");
        if (a.params.len > 16)
            @compileError("core/membrane/contract.zig: '" ++ a.name ++ "' has more params than wasm.zig's trampoline can carry (16)");
        if (a.results.len > 8)
            @compileError("core/membrane/contract.zig: '" ++ a.name ++ "' has more results than wasm.zig's trampoline can carry (8)");
        for (imports[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name))
                @compileError("core/membrane/contract.zig: duplicate wl_* import name '" ++ a.name ++ "'");
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────
// Belt-and-braces runtime checks alongside the comptime ones above: the
// comptime block already fails the BUILD on drift; these fail `zig build
// test` too (and double as executable documentation of the invariant).

const t = std.testing;

test "membrane contract: every entry is well-formed, documented, and unique" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(t.allocator);
    for (imports) |entry| {
        try t.expect(std.mem.startsWith(u8, entry.name, "wl_"));
        try t.expect(entry.doc.len > 0); // one-line doc, not blank
        try t.expect(entry.params.len <= 16 and entry.results.len <= 8);
        const gop = try seen.getOrPut(t.allocator, entry.name); // every bound import appears in the table exactly once
        try t.expect(!gop.found_existing);
    }
    try t.expectEqual(@as(usize, expected_count), imports.len);
}

test "membrane contract: defineImports binds every table entry onto a real linker" {
    // wasm_host.defineImports does nothing BUT walk this table now, so
    // successfully defining all 123 imports on a real wasmtime Linker is the
    // runtime proof that every entry has a bound, arity-consistent handler —
    // the comptime checks above catch shape drift; this catches the linker
    // actually accepting what the table describes. `dummy` is never
    // dereferenced: defineImports only boxes the pointer as opaque `data` for
    // later guest calls, which this test never makes.
    const wasm_host = @import("../wasm_host.zig");
    const WasmPlugin = @import("../wasm_abi/WasmPlugin.zig");
    var engine = try wasm.Engine.init();
    defer engine.deinit();
    var linker = try wasm.Linker.init(&engine);
    defer linker.deinit();
    var dummy: WasmPlugin = undefined;
    try wasm_host.defineImports(&linker, &dummy);
}
