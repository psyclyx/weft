//! core/membrane/contract.zig — the HOST side of the `weft.*` guest↔host
//! membrane: binds `contract_data.zig`'s pure data (name/params/results/
//! group/perm/doc) against this file's `handlers` (name → `HostFn`), and
//! provides the typed helpers that fire the host→guest EXPORT entrypoints
//! (`contract_data.exports`) instead of each call site naming a bare string.
//!
//! `wasm_host.defineImports` walks the zipped `imports` below to bind every
//! `wl_*` import onto the wasmtime Linker, instead of the (name, nparams,
//! nresults, handler) four-tuples wasm_host.zig used to hand-copy one at a
//! time. One source of truth kills the class of bug where a guest extern's
//! arity drifts from its host import's arity because someone edited one side
//! and forgot the other.
//!
//! Scope (doc/extensibility-native-surface.md, task W0a-D): this file covers the
//! HOST import side (zipping `contract_data.imports` with `handlers`) and
//! the host→guest export call-site helpers. It does NOT generate the guest
//! externs in src/guest/weft.zig (Zig 0.16 cannot reify a decl from a
//! comptime loop — see contract_data.zig's doc comment) — those stay
//! hand-written, comptime-VERIFIED against `contract_data.imports` from the
//! guest side instead. quickjs's `qjs_*` table is a separate file
//! (qjs_contract.zig, different marshalling path, not force-unified here).
//!
//! Not in scope: marshalling, scratch buffers, or handler bodies — those stay
//! exactly where they are (wasm_host/*.zig), unchanged.

const std = @import("std");
const wasm = @import("../wasm.zig");
const HostFn = wasm.Linker.HostFn;

const contract_data = @import("contract_data.zig");
pub const ValType = contract_data.ValType;
pub const Group = contract_data.Group;
pub const Perm = contract_data.Perm;

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
const semantic = @import("../wasm_host/semantic.zig");
const semantic_action = @import("../wasm_host/semantic_action.zig");
const semantic_field = @import("../wasm_host/semantic_field.zig");
const semantic_target = @import("../wasm_host/semantic_target.zig");
const semantic_relation = @import("../wasm_host/semantic_relation.zig");
const semantic_fs = @import("../wasm_host/semantic_fs.zig");
const transfer_attachment = @import("../wasm_host/transfer_attachment.zig");
const sessions = @import("../wasm_host/sessions.zig");
const slot = @import("../wasm_host/slot.zig");
const surface = @import("../wasm_host/surface.zig");
const syntax = @import("../wasm_host/syntax.zig");
const tool = @import("../wasm_host/tool.zig");

/// The full host-side entry: `contract_data.Entry`'s fields plus the bound
/// `HostFn`. Same shape `wasm_host.defineImports` and this file's tests
/// consumed before the data/handler split — consumers are unaffected.
pub const Entry = struct {
    name: []const u8,
    params: []const ValType,
    results: []const ValType,
    group: Group,
    handler: HostFn,
    perm: ?Perm = null,
    head_gated: bool = false,
    doc: []const u8,
};

/// name → handler, in the SAME grouping/order as `contract_data.imports`
/// (for review, not correctness — the zip below matches by name). Add a
/// handler here for every entry added to `contract_data.imports`; the
/// comptime zip fails the build if the two lists don't correspond exactly.
const handlers = [_]struct { name: []const u8, handler: HostFn }{
    // ── declare.zig — describe-phase declarations ──────────────────────
    .{ .name = "wl_log", .handler = declare.hLog },
    .{ .name = "wl_declare_command", .handler = declare.hDeclareCommand },
    .{ .name = "wl_declare_capability", .handler = declare.hDeclareCapability },
    .{ .name = "wl_request_perm", .handler = declare.hRequestPerm },

    // ── edit.zig — read-only, native editor step, write, anchored ranges ─
    .{ .name = "wl_cursor", .handler = edit.hCursor },
    .{ .name = "wl_byte_len", .handler = edit.hByteLen },
    .{ .name = "wl_doc_snapshot", .handler = edit.hDocSnapshot },
    .{ .name = "wl_doc_snapshot_is_current", .handler = edit.hDocSnapshotIsCurrent },
    .{ .name = "wl_doc_snapshot_release", .handler = edit.hDocSnapshotRelease },
    .{ .name = "wl_slice", .handler = edit.hSlice },
    .{ .name = "wl_line_at", .handler = edit.hLineAt },
    .{ .name = "wl_selection", .handler = edit.hSelection },
    .{ .name = "wl_path", .handler = edit.hPath },
    .{ .name = "wl_editor_step", .handler = edit.hEditorStep },
    .{ .name = "wl_set_selection", .handler = edit.hSetSelection },
    .{ .name = "wl_edit", .handler = edit.hEdit },
    .{ .name = "wl_render", .handler = edit.hRender },
    .{ .name = "wl_edit_as", .handler = edit.hEditAs },
    .{ .name = "wl_jump", .handler = edit.hJump },
    .{ .name = "wl_anchor_range", .handler = edit.hAnchorRange },
    .{ .name = "wl_set_result_range", .handler = edit.hSetResultRange },
    .{ .name = "wl_run_range", .handler = edit.hRunRange },
    .{ .name = "wl_range_ends", .handler = edit.hRangeEnds },
    .{ .name = "wl_range_retain", .handler = edit.hRangeRetain },
    .{ .name = "wl_range_release", .handler = edit.hRangeRelease },
    .{ .name = "wl_run_range_arg", .handler = edit.hRunRangeArg },
    .{ .name = "wl_arg_range", .handler = edit.hArgRange },
    .{ .name = "wl_edit_range", .handler = edit.hEditRange },

    // ── layers.zig — flash/style/fold/readonly/decorate/breakpoints ────
    .{ .name = "wl_flash", .handler = layers.hFlash },
    .{ .name = "wl_style_clear", .handler = layers.hStyleClear },
    .{ .name = "wl_style", .handler = layers.hStyle },
    .{ .name = "wl_fold_clear", .handler = layers.hFoldClear },
    .{ .name = "wl_fold", .handler = layers.hFold },
    .{ .name = "wl_readonly_clear", .handler = layers.hReadOnlyClear },
    .{ .name = "wl_readonly_span", .handler = layers.hReadOnlySpan },
    .{ .name = "wl_decorate_clear", .handler = layers.hDecorateClear },
    .{ .name = "wl_decorate", .handler = layers.hDecorate },
    .{ .name = "wl_breakpoint_publish", .handler = layers.hBreakpointPublish },

    // ── config_kv.zig — runtime kv scratch + the distinct config store ──
    .{ .name = "wl_kv_get", .handler = config_kv.hKvGet },
    .{ .name = "wl_kv_put", .handler = config_kv.hKvPut },
    .{ .name = "wl_config_get", .handler = config_kv.hConfigGet },

    // ── dispatch.zig — echo + command args in/result out ───────────────
    .{ .name = "wl_echo", .handler = dispatch.hEcho },
    .{ .name = "wl_arg_count", .handler = dispatch.hArgCount },
    .{ .name = "wl_arg_int", .handler = dispatch.hArgInt },
    .{ .name = "wl_arg_str", .handler = dispatch.hArgStr },
    .{ .name = "wl_set_result_int", .handler = dispatch.hSetResultInt },
    .{ .name = "wl_set_result_str", .handler = dispatch.hSetResultStr },

    // ── keymap.zig — the local config plane: bindings/modes/providers ──
    .{ .name = "wl_bind_key", .handler = keymap.hBindKey },
    .{ .name = "wl_set_mode", .handler = keymap.hSetMode },
    .{ .name = "wl_set_fallback", .handler = keymap.hSetFallback },
    .{ .name = "wl_text_input", .handler = keymap.hTextInput },
    .{ .name = "wl_menu_mode", .handler = keymap.hMenuMode },
    .{ .name = "wl_locked_mode", .handler = keymap.hLockedMode },
    .{ .name = "wl_resting_mode", .handler = keymap.hRestingMode },
    .{ .name = "wl_exit_to_resting", .handler = keymap.hExitToResting },
    .{ .name = "wl_sticky_menu", .handler = keymap.hStickyMenu },
    .{ .name = "wl_declare_action", .handler = keymap.hDeclareAction },
    .{ .name = "wl_provide", .handler = keymap.hProvide },

    // ── commands.zig — register/run/introspect ──────────────────────────
    .{ .name = "wl_register", .handler = commands.hRegister },
    .{ .name = "wl_run", .handler = commands.hRun },
    .{ .name = "wl_run_int", .handler = commands.hRunInt },
    .{ .name = "wl_run_str", .handler = commands.hRunStr },
    .{ .name = "wl_run_str2", .handler = commands.hRunStr2 },
    .{ .name = "wl_command_count", .handler = commands.hCommandCount },
    .{ .name = "wl_command_name", .handler = commands.hCommandName },
    .{ .name = "wl_command_summary", .handler = commands.hCommandSummary },

    // ── buffers.zig — the open-buffer list (introspection) ──────────────
    .{ .name = "wl_buffer_count", .handler = buffers.hBufferCount },
    .{ .name = "wl_buffer_id", .handler = buffers.hBufferId },
    .{ .name = "wl_buffer_name", .handler = buffers.hBufferName },
    .{ .name = "wl_buffer_active", .handler = buffers.hBufferActive },
    .{ .name = "wl_buffer_readonly", .handler = buffers.hBufferReadonly },

    // ── pick.zig — fuzzy pick build/open/accept ─────────────────────────
    .{ .name = "wl_pick_begin", .handler = pick.hPickBegin },
    .{ .name = "wl_pick_add", .handler = pick.hPickAdd },
    .{ .name = "wl_pick_end", .handler = pick.hPickEnd },
    .{ .name = "wl_open_file_pick", .handler = pick.hOpenFilePick },
    .{ .name = "wl_pick_outcome_kind", .handler = pick.hPickOutcomeKind },
    .{ .name = "wl_pick_outcome_text", .handler = pick.hPickOutcomeText },
    .{ .name = "wl_pick_outcome_query", .handler = pick.hPickOutcomeQuery },
    .{ .name = "wl_pick_outcome_index", .handler = pick.hPickOutcomeIndex },
    .{ .name = "wl_pick_outcome_match_start", .handler = pick.hPickOutcomeMatchStart },
    .{ .name = "wl_pick_outcome_match_span", .handler = pick.hPickOutcomeMatchSpan },

    // ── menu.zig — which-key style menu-mode binding introspection ─────
    .{ .name = "wl_menu_binding_count", .handler = menu.hMenuBindingCount },
    .{ .name = "wl_menu_binding_key", .handler = menu.hMenuBindingKey },
    .{ .name = "wl_menu_binding_cmd", .handler = menu.hMenuBindingCmd },
    .{ .name = "wl_menu_binding_is_group", .handler = menu.hMenuBindingIsGroup },

    // ── surface.zig — the retained overlay (which-key/dired/magit) ─────
    .{ .name = "wl_surface_begin", .handler = surface.hSurfaceBegin },
    .{ .name = "wl_surface_caret", .handler = surface.hSurfaceCaret },
    .{ .name = "wl_surface_row", .handler = surface.hSurfaceRow },
    .{ .name = "wl_surface_span", .handler = surface.hSurfaceSpan },
    .{ .name = "wl_surface_end", .handler = surface.hSurfaceEnd },
    .{ .name = "wl_surface_close", .handler = surface.hSurfaceClose },

    // ── capability.zig — the completion provider gather/push ───────────
    .{ .name = "wl_provide_completion", .handler = capability.hProvideCompletion },
    .{ .name = "wl_completion_prefix", .handler = capability.hCompletionPrefix },
    .{ .name = "wl_caps_item", .handler = capability.hCapsItem },
    .{ .name = "wl_caps_commit", .handler = capability.hCapsCommit },
    .{ .name = "wl_caps_decline", .handler = capability.hCapsDecline },

    // ── syntax.zig — structural (tree-sitter) read + subbuffers ────────
    .{ .name = "wl_node_at", .handler = syntax.hNodeAt },
    .{ .name = "wl_node_enclosing", .handler = syntax.hNodeEnclosing },
    .{ .name = "wl_query", .handler = syntax.hQuery },
    .{ .name = "wl_query_capture", .handler = syntax.hQueryCapture },
    .{ .name = "wl_node_children", .handler = syntax.hNodeChildren },
    .{ .name = "wl_claim_subbuffer", .handler = syntax.hClaimSubbuffer },
    .{ .name = "wl_subbuffer_put_fact", .handler = syntax.hSubbufferPutFact },
    .{ .name = "wl_subbuffer_clear", .handler = syntax.hSubbufferClear },
    .{ .name = "wl_subbuffer_fact_at", .handler = syntax.hSubbufferFactAt },

    // ── activation.zig — the focus event ────────────────────────────────
    .{ .name = "wl_activate_path", .handler = activation.hActivatePath },

    // ── tool.zig — projection ownership ─────────────────────────────────
    .{ .name = "wl_tool_backing", .handler = tool.hToolBacking },

    // ── register.zig — the editor-agnostic yank/paste service ──────────
    .{ .name = "wl_yank_range", .handler = register.hYankRange },
    .{ .name = "wl_register_text", .handler = register.hRegisterText },
    .{ .name = "wl_register_linewise", .handler = register.hRegisterLinewise },
    .{ .name = "wl_paste_at", .handler = register.hPasteAt },

    // ── semantic.zig — generic focused-view actions ───────────────────
    .{ .name = "wl_semantic_active", .handler = semantic.hSemanticActive },
    .{ .name = "wl_semantic_working_target", .handler = semantic.hSemanticWorkingTarget },
    .{ .name = "wl_semantic_view_focus", .handler = semantic.hSemanticViewFocus },
    .{ .name = "wl_semantic_interaction_open", .handler = semantic.hSemanticInteractionOpen },
    .{ .name = "wl_semantic_interaction_close", .handler = semantic.hSemanticInteractionClose },
    .{ .name = "wl_semantic_action", .handler = semantic.hSemanticAction },
    .{ .name = "wl_semantic_target_publish", .handler = semantic.hSemanticTargetPublish },
    .{ .name = "wl_semantic_target_replace", .handler = semantic.hSemanticTargetReplace },
    .{ .name = "wl_semantic_target_close", .handler = semantic.hSemanticTargetClose },
    .{ .name = "wl_semantic_target_describe_len", .handler = semantic.hSemanticTargetDescribeLen },
    .{ .name = "wl_semantic_target_describe", .handler = semantic.hSemanticTargetDescribe },
    .{ .name = "wl_semantic_view_publish", .handler = semantic.hSemanticViewPublish },
    .{ .name = "wl_semantic_view_replace", .handler = semantic.hSemanticViewReplace },
    .{ .name = "wl_semantic_view_close", .handler = semantic.hSemanticViewClose },
    .{ .name = "wl_semantic_field_register", .handler = semantic_field.hFieldRegister },
    .{ .name = "wl_semantic_field_update", .handler = semantic_field.hFieldUpdate },
    .{ .name = "wl_semantic_field_close", .handler = semantic_field.hFieldClose },
    .{ .name = "wl_semantic_field_edit_meta", .handler = semantic_field.hFieldEditMeta },
    .{ .name = "wl_semantic_field_edit_revision", .handler = semantic_field.hFieldEditRevision },
    .{ .name = "wl_semantic_field_edit_replacement", .handler = semantic_field.hFieldEditReplacement },
    .{ .name = "wl_semantic_action_provider", .handler = semantic_action.hProvider },
    .{ .name = "wl_semantic_action_request_len", .handler = semantic_action.hRequestLen },
    .{ .name = "wl_semantic_action_request", .handler = semantic_action.hRequest },
    .{ .name = "wl_semantic_action_respond", .handler = semantic_action.hRespond },
    .{ .name = "wl_semantic_target_handler_register", .handler = semantic_target.hRegister },
    .{ .name = "wl_semantic_target_handler_close", .handler = semantic_target.hClose },
    .{ .name = "wl_semantic_target_handler_request_len", .handler = semantic_target.hRequestLen },
    .{ .name = "wl_semantic_target_handler_request", .handler = semantic_target.hRequest },
    .{ .name = "wl_semantic_target_handler_probe_respond", .handler = semantic_target.hProbeRespond },
    .{ .name = "wl_semantic_target_handler_open_respond", .handler = semantic_target.hOpenRespond },
    .{ .name = "wl_semantic_relation_provider_register", .handler = semantic_relation.hRegister },
    .{ .name = "wl_semantic_relation_provider_close", .handler = semantic_relation.hClose },
    .{ .name = "wl_semantic_relation_request_len", .handler = semantic_relation.hRequestLen },
    .{ .name = "wl_semantic_relation_request", .handler = semantic_relation.hRequest },
    .{ .name = "wl_semantic_relation_respond", .handler = semantic_relation.hRespond },
    .{ .name = "wl_semantic_transfer_capture", .handler = transfer_attachment.hCapture },
    .{ .name = "wl_semantic_transfer_retain", .handler = transfer_attachment.hRetain },
    .{ .name = "wl_semantic_transfer_release", .handler = transfer_attachment.hRelease },

    // ── proc.zig — perm-gated off-thread process effects ───────────────
    .{ .name = "wl_shell_insert", .handler = proc.hShellInsert },
    .{ .name = "wl_proc_spawn", .handler = proc.hProcSpawn },
    .{ .name = "wl_proc_send", .handler = proc.hProcSend },
    .{ .name = "wl_proc_read", .handler = proc.hProcRead },
    .{ .name = "wl_proc_close", .handler = proc.hProcClose },
    .{ .name = "wl_cwd", .handler = proc.hCwd },
    .{ .name = "wl_proc_to_buffer", .handler = proc.hProcToBuffer },
    .{ .name = "wl_proc_append_buffer", .handler = proc.hProcAppendBuffer },
    .{ .name = "wl_proc_filter", .handler = proc.hProcFilter },

    // ── sessions.zig — persistent streamed REPL + net sessions ─────────
    .{ .name = "wl_repl_start", .handler = sessions.hReplStart },
    .{ .name = "wl_repl_send", .handler = sessions.hReplSend },
    .{ .name = "wl_repl_quit", .handler = sessions.hReplQuit },
    .{ .name = "wl_net_connect", .handler = sessions.hNetConnect },
    .{ .name = "wl_net_send", .handler = sessions.hNetSend },
    .{ .name = "wl_net_close", .handler = sessions.hNetClose },

    // ── fs.zig — perm-gated local filesystem doors ─────────────────────
    .{ .name = "wl_fs_read", .handler = fs.hFsRead },
    .{ .name = "wl_fs_exists", .handler = fs.hFsExists },
    .{ .name = "wl_fs_write", .handler = fs.hFsWrite },
    .{ .name = "wl_fs_append", .handler = fs.hFsAppend },
    .{ .name = "wl_fs_list", .handler = fs.hFsList },
    .{ .name = "wl_fs_list_async", .handler = fs.hFsListAsync },
    .{ .name = "wl_semantic_fs_publish_child_directory", .handler = semantic_fs.hPublishChildDirectory },
    .{ .name = "wl_semantic_fs_publish_child_file", .handler = semantic_fs.hPublishChildFile },
    .{ .name = "wl_semantic_fs_capabilities", .handler = semantic_fs.hCapabilities },
    .{ .name = "wl_semantic_fs_list", .handler = semantic_fs.hList },
    .{ .name = "wl_semantic_fs_apply", .handler = semantic_fs.hApply },

    // ── slot.zig — D2's generic, schema-directed membrane verbs ────────
    .{ .name = "wl_slot_declare", .handler = slot.hSlotDeclare },
    .{ .name = "wl_slot_bind", .handler = slot.hSlotBind },
    .{ .name = "wl_payload_push", .handler = slot.hPayloadPush },
    .{ .name = "wl_payload_read", .handler = slot.hPayloadRead },
};

/// Zip `contract_data.imports` (data) with `handlers` (binding) by NAME —
/// not position, so reordering either list can't silently mismatch a
/// handler onto the wrong import. Both directions are checked: every data
/// entry must find a handler (else `defineImports` would silently bind
/// nothing for it — caught here instead), and `handlers.len` must equal
/// `contract_data.imports.len` (an extra handler with no data entry, e.g. a
/// stale rename, is otherwise invisible).
fn zip() [contract_data.imports.len]Entry {
    @setEvalBranchQuota(200_000); // O(n²) name matching, n≈124
    if (handlers.len != contract_data.imports.len) @compileError(std.fmt.comptimePrint(
        "core/membrane/contract.zig: {d} handlers bound but contract_data.imports has {d} entries " ++
            "— a handler was added/removed without updating the other list.",
        .{ handlers.len, contract_data.imports.len },
    ));
    var out: [contract_data.imports.len]Entry = undefined;
    for (contract_data.imports, 0..) |d, i| {
        var found = false;
        for (handlers) |h| {
            if (std.mem.eql(u8, h.name, d.name)) {
                out[i] = .{ .name = d.name, .params = d.params, .results = d.results, .group = d.group, .handler = h.handler, .perm = d.perm, .head_gated = d.head_gated, .doc = d.doc };
                found = true;
                break;
            }
        }
        if (!found) @compileError("core/membrane/contract.zig: no handler bound for wl_* import '" ++ d.name ++ "' declared in contract_data.zig");
    }
    return out;
}

/// The membrane's host-import table: one entry per `weft.wl_*` import the
/// guest shim declares. `wasm_host.defineImports` walks this to bind the
/// Linker — nothing else in the host tree defines a `weft.*` import; add or
/// change one here (in `contract_data.imports` + `handlers` above), and
/// mirror the extern in src/guest/weft.zig by hand (comptime-verified, see
/// that file).
pub const imports: [contract_data.imports.len]Entry = zip();

// ── Host→guest export call sites: typed helpers over contract_data.exports ─

fn findExport(comptime name: []const u8) contract_data.Export {
    for (contract_data.exports) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    @compileError("core/membrane/contract.zig: '" ++ name ++ "' is not a declared guest export — add it to contract_data.exports first");
}

/// Call a REQUIRED guest export (`contract_data.exports[..].required = true`,
/// e.g. `init`/`on_command`): a compile error if `name` isn't in the table,
/// or if the table doesn't mark it required — so a call site can't silently
/// assume presence for something the table says is optional. `args` is an
/// anonymous tuple literal (`.{}`, `.{x}`, ...) — coercing it to the export's
/// exact `[N]i32` arity is itself a compile-time check (a wrong-arity call
/// fails to coerce). Otherwise a thin, behavior-preserving pass to
/// `instance.callVoid` — this helper does not itself swallow any error; the
/// call site's own `try`/`catch` (as today) decides what a failure means.
pub fn callRequiredExport(comptime name: []const u8, instance: *wasm.Instance, args: anytype) wasm.Error!void {
    const e = comptime findExport(name);
    if (!e.required) @compileError("core/membrane/contract.zig: export '" ++ name ++ "' is optional in contract_data.exports — use callOptionalExport");
    const arr: [e.params.len]i32 = args;
    return instance.callVoid(name, &arr);
}

/// Call an OPTIONAL guest export (`required = false`, e.g. `on_menu`): a
/// compile error if `name` isn't in the table, or if the table marks it
/// required (an optional-only helper used on a required export would hide a
/// real bug). Like `callRequiredExport`, this is a thin pass-through — the
/// existing per-call-site tolerance (some sites swallow every error,
/// `describe` swallows only `error.MissingExport`) is preserved verbatim by
/// leaving that decision at the call site, not centralizing it here (the
/// two patterns differ today; unifying them would be a behavior change).
pub fn callOptionalExport(comptime name: []const u8, instance: *wasm.Instance, args: anytype) wasm.Error!void {
    const e = comptime findExport(name);
    if (e.required) @compileError("core/membrane/contract.zig: export '" ++ name ++ "' is required in contract_data.exports — use callRequiredExport");
    const arr: [e.params.len]i32 = args;
    return instance.callVoid(name, &arr);
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
    try t.expectEqual(@as(usize, contract_data.imports.len), imports.len);
}

test "membrane contract: defineImports binds every table entry onto a real linker" {
    // wasm_host.defineImports does nothing BUT walk this table now, so
    // successfully defining all 124 imports on a real wasmtime Linker is the
    // runtime proof that every entry has a bound, arity-consistent handler —
    // the comptime checks above catch shape drift; this catches the linker
    // actually accepting what the table describes. `dummy` is never
    // dereferenced: defineImports only boxes the pointer as opaque `data` for
    // later guest calls, which this test never makes.
    const wasm_host = @import("../wasm_host.zig");
    const WasmPlugin = @import("../wasm_abi/WasmPlugin.zig");
    var engine = try wasm.Engine.init(t.allocator);
    defer engine.deinit();
    var linker = try wasm.Linker.init(&engine);
    defer linker.deinit();
    var dummy: WasmPlugin = undefined;
    try wasm_host.defineImports(&linker, &dummy);
}

/// The perm-drift cross-check (opus review of W0a-C, task W0a-D): a CURATED
/// list of every `wl_*` import whose handler actually gates on a
/// `requirePerm(p, caller, .x)` call (grep `requirePerm(` across
/// wasm_host/*.zig to reproduce/update this list — there is no way to walk
/// a function BODY at comptime, so this is hand-maintained, not derived).
/// `proc_timer` here means the handler gates BOTH `.proc` and `.timer`
/// (always as a pair — see `Perm`'s doc comment); an entry gating only one
/// of the two would be a real, single `Perm` value instead.
///
/// Why a runtime test over a curated list, not a comptime block: Zig has no
/// way to inspect a `pub fn hFoo(...)`'s BODY for which `requirePerm` calls
/// it makes — that's control flow, not a type or a declaration comptime can
/// walk. A test that hand-lists the enforcement sites and diffs both
/// directions against `contract_data.zig`'s `.perm` metadata is the
/// documented, honest middle ground: it can't catch a NEW ungated effectful
/// handler (nothing forces this list to grow when one is added — same as
/// today), but it DOES fail the moment `.perm` in the table and the actual
/// `requirePerm` gate disagree for anything on this list, in EITHER
/// direction (table says gated but code doesn't enforce it, or vice versa)
/// — which is exactly the silent-drift class the review flagged.
const perm_gated = [_]struct { name: []const u8, perm: Perm }{
    .{ .name = "wl_shell_insert", .perm = .proc_timer }, // proc.zig hShellInsert: .proc + .timer
    .{ .name = "wl_proc_spawn", .perm = .proc }, // proc.zig hProcSpawn: .proc only (no .timer)
    .{ .name = "wl_proc_to_buffer", .perm = .proc_timer }, // proc.zig hProcToBuffer: .proc + .timer
    .{ .name = "wl_proc_append_buffer", .perm = .proc_timer }, // proc.zig hProcAppendBuffer: .proc + .timer
    .{ .name = "wl_proc_filter", .perm = .proc_timer }, // proc.zig hProcFilter: .proc + .timer
    .{ .name = "wl_repl_start", .perm = .proc_timer }, // sessions.zig hReplStart: .proc + .timer
    .{ .name = "wl_net_connect", .perm = .net }, // sessions.zig hNetConnect: .net
    .{ .name = "wl_fs_read", .perm = .fs_read }, // fs.zig hFsRead: .fs_read
    .{ .name = "wl_fs_exists", .perm = .fs_read }, // fs.zig hFsExists: .fs_read
    .{ .name = "wl_fs_write", .perm = .fs_write }, // fs.zig hFsWrite: .fs_write
    .{ .name = "wl_fs_append", .perm = .fs_write }, // fs.zig hFsAppend: .fs_write
    .{ .name = "wl_fs_list", .perm = .fs_read }, // fs.zig hFsList: .fs_read
    .{ .name = "wl_fs_list_async", .perm = .fs_read }, // fs.zig hFsListAsync: .fs_read
    .{ .name = "wl_semantic_fs_publish_child_directory", .perm = .fs_read }, // semantic_fs.zig hPublishChildDirectory: .fs_read
    .{ .name = "wl_semantic_fs_publish_child_file", .perm = .fs_read }, // semantic_fs.zig hPublishChildFile: .fs_read
    .{ .name = "wl_semantic_fs_capabilities", .perm = .fs_read }, // semantic_fs.zig hCapabilities: .fs_read
    .{ .name = "wl_semantic_fs_list", .perm = .fs_read }, // semantic_fs.zig hList: .fs_read
    .{ .name = "wl_semantic_fs_apply", .perm = .fs_write }, // semantic_fs.zig hApply: .fs_write
    .{ .name = "wl_semantic_transfer_capture", .perm = .fs_read }, // transfer_attachment.zig hCapture: .fs_read
};

test "membrane contract: table .perm metadata agrees with the handlers' actual requirePerm gates" {
    // Direction 1: every curated (actually-gated) import must have the SAME
    // perm in the table — a table edit that changes/drops `.perm` without
    // touching the handler (or vice versa) fails here.
    for (perm_gated) |g| {
        var found = false;
        for (imports) |entry| {
            if (!std.mem.eql(u8, entry.name, g.name)) continue;
            found = true;
            try t.expectEqual(g.perm, entry.perm orelse {
                std.debug.print("membrane contract: '{s}' is requirePerm-gated ({t}) but contract_data.zig has .perm = null\n", .{ g.name, g.perm });
                return error.TestExpectedEqual;
            });
        }
        try t.expect(found); // the curated name must be a real import
    }
    // Direction 2: every table entry that CLAIMS a perm gate must be on the
    // curated (verified-gated) list — an entry with `.perm` set but no
    // matching requirePerm call would otherwise silently over-claim.
    for (imports) |entry| {
        const want = entry.perm orelse continue;
        var found = false;
        for (perm_gated) |g| {
            if (std.mem.eql(u8, g.name, entry.name)) {
                try t.expectEqual(want, g.perm);
                found = true;
            }
        }
        if (!found) std.debug.print("membrane contract: '{s}' claims .perm = {t} but isn't on the curated perm_gated list (see this test's doc comment)\n", .{ entry.name, want });
        try t.expect(found);
    }
}

/// The dispatch-gating cross-check (task #19 item 4), same shape as
/// `perm_gated` above: a CURATED list of every `wl_*` import whose handler
/// actually gates on `requireDispatch(p, caller, ..)` (grep `requireDispatch(`
/// across wasm_host/*.zig to reproduce/update this list — same "no way to
/// walk a function body at comptime" rationale as `perm_gated`'s doc).
const head_gated_list = [_][]const u8{
    "wl_set_mode", // keymap.zig hSetMode
    "wl_exit_to_resting", // keymap.zig hExitToResting
    "wl_echo", // dispatch.zig hEcho
    "wl_pick_end", // pick.zig hPickEnd
    "wl_open_file_pick", // pick.zig hOpenFilePick
    "wl_semantic_working_target", // semantic.zig hSemanticWorkingTarget
    "wl_semantic_view_focus", // semantic.zig hSemanticViewFocus
    "wl_semantic_interaction_open", // semantic.zig hSemanticInteractionOpen
    "wl_semantic_interaction_close", // semantic.zig hSemanticInteractionClose
    "wl_semantic_action", // semantic.zig hSemanticAction
};

test "membrane contract: table .head_gated metadata agrees with the handlers' actual requireDispatch gates" {
    // LIMITATION (stated so this test isn't over-trusted): this proves
    // gated ⇔ curated-list agreement — it CANNOT prove completeness (that
    // every head-state WRITER in wasm_host/* is gated). An ungated handler
    // that reaches head.echo/mode/pick on some branch is invisible here;
    // finding those takes the review-style sweep of `.head` touches (which
    // is how the wl_provide error-path echo was caught and gated).
    // Direction 1: every curated (actually-gated) import must be marked
    // `.head_gated = true` in the table.
    for (head_gated_list) |name| {
        var found = false;
        for (imports) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            found = true;
            if (!entry.head_gated) {
                std.debug.print("membrane contract: '{s}' is requireDispatch-gated but contract_data.zig has .head_gated = false\n", .{name});
                return error.TestExpectedEqual;
            }
        }
        try t.expect(found); // the curated name must be a real import
    }
    // Direction 2: every table entry that CLAIMS `.head_gated = true` must be
    // on the curated (verified-gated) list — a table edit that flips the bit
    // without wiring the handler's `requireDispatch` call would otherwise
    // silently over-claim the guarantee.
    for (imports) |entry| {
        if (!entry.head_gated) continue;
        var found = false;
        for (head_gated_list) |name| {
            if (std.mem.eql(u8, name, entry.name)) found = true;
        }
        if (!found) std.debug.print("membrane contract: '{s}' claims .head_gated = true but isn't on the curated head_gated_list (see this test's doc comment)\n", .{entry.name});
        try t.expect(found);
    }
}
