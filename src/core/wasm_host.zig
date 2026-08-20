//! wasm_host — the `weft.*` host-import table: one small function per abi.Abi
//! method the guest shim (src/guest/weft.zig) imports, each marshalling to
//! command.Context across the sandbox membrane, plus the trampolines that
//! dispatch back into the guest (commands, pick accept, completion provider)
//! and the deferred shell-insert machinery. Split from wasm_abi.zig — which
//! owns the WasmPlugin lifecycle + handshake — to keep each file focused on
//! one concern; the two @import each other (Zig permits the cycle).

const wasm = @import("wasm.zig");

// The lifecycle side owns the plugin type; `defineImports` binds over it. The
// two @import each other (Zig permits the file-level cycle).
const wasm_abi = @import("wasm_abi.zig");
const WasmPlugin = wasm_abi.WasmPlugin;

// The shared leaf every handler group imports (WasmPlugin, perms, environ,
// the peer resolver). Re-exported below so `core.wasm_host.X` is unchanged.
const plugin = @import("wasm_host/plugin.zig");
pub const perm_fs_read = plugin.perm_fs_read;
pub const perm_fs_write = plugin.perm_fs_write;
pub const perm_net = plugin.perm_net;
pub const perm_proc = plugin.perm_proc;
pub const perm_timer = plugin.perm_timer;
pub const setEnviron = plugin.setEnviron;
pub fn hostEnviron() @import("std").process.Environ {
    return plugin.g_environ;
}
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
const edit = @import("wasm_host/edit.zig");
const register_host = @import("wasm_host/register.zig");
const tool_host = @import("wasm_host/tool.zig");

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
    try d(linker, "wl_cursor", 0, 1, edit.hCursor, p);
    try d(linker, "wl_byte_len", 0, 1, edit.hByteLen, p);
    try d(linker, "wl_slice", 4, 1, edit.hSlice, p);
    try d(linker, "wl_line_at", 2, 0, edit.hLineAt, p);
    try d(linker, "wl_selection", 1, 1, edit.hSelection, p);
    try d(linker, "wl_path", 2, 1, edit.hPath, p);
    // Group B: the native `editor` surface (pure step primitive).
    try d(linker, "wl_editor_step", 3, 1, edit.hEditorStep, p);
    try d(linker, "wl_set_selection", 2, 0, edit.hSetSelection, p);
    // Group C: write.
    try d(linker, "wl_edit", 4, 0, edit.hEdit, p);
    try d(linker, "wl_render", 4, 0, edit.hRender, p);
    try d(linker, "wl_edit_as", 6, 0, edit.hEditAs, p);
    try d(linker, "wl_register", 2, 1, commands.hRegister, p);
    try d(linker, "wl_jump", 1, 0, edit.hJump, p);
    try d(linker, "wl_flash", 2, 0, layers.hFlash, p);
    // Styles feed: a plugin paints per-byte StyleClass over its (active) tool
    // buffer; the view renders it through Theme.styleColor (git/grep coloring).
    try d(linker, "wl_style_clear", 0, 0, layers.hStyleClear, p);
    try d(linker, "wl_style", 3, 0, layers.hStyle, p);
    try d(linker, "wl_fold_clear", 0, 0, layers.hFoldClear, p);
    try d(linker, "wl_fold", 2, 0, layers.hFold, p);
    try d(linker, "wl_readonly_clear", 0, 0, layers.hReadOnlyClear, p);
    try d(linker, "wl_readonly_span", 2, 0, layers.hReadOnlySpan, p);
    // Placed decorations: virtual text drawn beside the line (metadata-is-
    // decoration) — never document bytes, so yy never yanks it.
    try d(linker, "wl_decorate_clear", 0, 0, layers.hDecorateClear, p);
    try d(linker, "wl_decorate", 5, 0, layers.hDecorate, p);
    // Stamped ranges ([FIX 1/3]): a motion returns one, an operator awaits +
    // applies it. Handles cross; the version token stays host-side.
    try d(linker, "wl_stamp_range", 2, 1, edit.hStampRange, p);
    try d(linker, "wl_set_result_range", 1, 0, edit.hSetResultRange, p);
    try d(linker, "wl_run_range", 2, 1, edit.hRunRange, p);
    try d(linker, "wl_range_ends", 2, 1, edit.hRangeEnds, p);
    try d(linker, "wl_run_range_arg", 3, 0, edit.hRunRangeArg, p);
    try d(linker, "wl_arg_range", 1, 1, edit.hArgRange, p);
    try d(linker, "wl_edit_range", 3, 0, edit.hEditRange, p);
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
    try d(linker, "wl_locked_mode", 2, 0, keymap.hLockedMode, p);
    try d(linker, "wl_sticky_menu", 2, 0, keymap.hStickyMenu, p);
    try d(linker, "wl_declare_action", 2, 0, keymap.hDeclareAction, p);
    try d(linker, "wl_provide", 11, 0, keymap.hProvide, p);
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
    try d(linker, "wl_subbuffer_clear", 0, 0, syntax_host.hSubbufferClear, p);
    try d(linker, "wl_subbuffer_fact_at", 5, 1, syntax_host.hSubbufferFactAt, p);
    // Tool-backed projection: a save fires the owner's on_save reconcile.
    try d(linker, "wl_tool_backing", 2, 0, tool_host.hToolBacking, p);
    // Register/kill service: the editor-agnostic yank/paste that ferries a
    // subbuffer's facts (a projection row's hidden id) across dd→p (register.zig).
    try d(linker, "wl_yank_range", 3, 0, register_host.hYankRange, p);
    try d(linker, "wl_register_text", 2, 1, register_host.hRegisterText, p);
    try d(linker, "wl_register_linewise", 0, 1, register_host.hRegisterLinewise, p);
    try d(linker, "wl_paste_at", 1, 0, register_host.hPasteAt, p);
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
    try d(linker, "wl_fs_exists", 2, 1, fs.hFsExists, p);
    try d(linker, "wl_fs_write", 4, 1, fs.hFsWrite, p);
    try d(linker, "wl_fs_append", 4, 1, fs.hFsAppend, p);
    try d(linker, "wl_fs_list", 6, 1, fs.hFsList, p);
    try d(linker, "wl_fs_list_async", 6, 1, fs.hFsListAsync, p);
}
