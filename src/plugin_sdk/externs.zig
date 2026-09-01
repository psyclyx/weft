//! `plugin_sdk/externs.zig` — THE DOORS. Every `weft.*` host import a guest
//! can reach, and nothing else: 231 hand-written `extern "weft"` declarations
//! plus the comptime tripwire that holds them to the host's table.
//!
//! Split out of root.zig so the membrane's actual surface — what doors exist,
//! what each one takes, which permission gates it — is one auditable file
//! rather than 231 declarations threaded through three thousand lines of
//! ergonomics. The wrappers guest code actually calls stay in root.zig and
//! reach these through `e.wl_*`.
//!
//! `pub` only so root.zig can call them. A plugin cannot reach this file: a
//! guest is its own module rooted at its own directory, so a relative import
//! into the SDK's implementation does not compile, and the SDK is exposed to
//! guests only as the module `weft`, whose root is root.zig.
//!
//! The comptime block at the bottom lives HERE, with the externs, because it
//! resolves each one by name through `@field(@This(), entry.name)` — it can
//! only verify the namespace it sits in.

const std = @import("std");

/// The pure-data half of the membrane contract (membrane/root.zig) — no
/// wasmtime/wasm_host dependency, so it compiles here under
/// wasm32-freestanding same as the host side does. Used ONLY by the comptime
/// verification block below; the ergonomic wrappers don't reference it.
const contract_data = @import("weft_membrane");

// ── Raw host imports (the grants). Named `wl_*` to keep the ergonomic
// wrappers below as the surface guest code actually calls. Hand-written —
// Zig 0.16 can't synthesize an `extern fn` declaration from a comptime loop
// (no `@Type`, no `usingnamespace` decl-merging) — but comptime-VERIFIED
// against `contract_data.imports` below: an arity or signedness slip here,
// or an extern this file forgot to add/remove after the table changed,
// fails the BUILD (see the `comptime` block right after the extern list),
// not a silent runtime drift. ──
pub extern "weft" fn wl_log(level: u32, ptr: u32, len: u32) void;
pub extern "weft" fn wl_declare_command(ptr: u32, len: u32) void;
pub extern "weft" fn wl_declare_command_doc(ptr: u32, len: u32, params: u32, params_len: u32, summary: u32, summary_len: u32) void;
pub extern "weft" fn wl_declare_capability(ptr: u32, len: u32) void;
pub extern "weft" fn wl_request_perm(perm: u32) void;
pub extern "weft" fn wl_cursor() u32;
pub extern "weft" fn wl_byte_len() u32;
pub extern "weft" fn wl_doc_snapshot() i32;
pub extern "weft" fn wl_doc_snapshot_is_current(handle: u32) u32;
pub extern "weft" fn wl_doc_snapshot_release(handle: u32) void;
pub extern "weft" fn wl_slice(start: u32, end: u32, out_ptr: u32, out_cap: u32) u32;
pub extern "weft" fn wl_line_at(offset: u32, out_ptr: u32) void;
pub extern "weft" fn wl_selection(out_ptr: u32) u32;
pub extern "weft" fn wl_path(out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_edit(start: u32, end: u32, ptr: u32, len: u32) void;
pub extern "weft" fn wl_render(start: u32, end: u32, ptr: u32, len: u32) void;
pub extern "weft" fn wl_edit_as(agent: u32, agent_len: u32, start: u32, end: u32, ptr: u32, len: u32) void;
pub extern "weft" fn wl_register(ptr: u32, len: u32) u32;
pub extern "weft" fn wl_jump(offset: u32) void;
pub extern "weft" fn wl_flash(start: u32, end: u32) void;
pub extern "weft" fn wl_fold_clear() void;
pub extern "weft" fn wl_fold(start: u32, end: u32) void;
pub extern "weft" fn wl_decorate_clear() void;
pub extern "weft" fn wl_decorate(anchor: u32, placement: u32, role: u32, ptr: u32, len: u32) void;
pub extern "weft" fn wl_breakpoint_toggle(offset: u32) i32;
pub extern "weft" fn wl_breakpoint_clear() void;
pub extern "weft" fn wl_breakpoint_offsets(ptr: u32, cap: u32) i32;
// Annotation layers: decorate an entry this plugin does not own (§11.7).
pub extern "weft" fn wl_annotate_open(entry: u32, ptr: u32, len: u32) i32;
pub extern "weft" fn wl_annotate_close(handle: u32) void;
pub extern "weft" fn wl_annotate_len(handle: u32) i32;
pub extern "weft" fn wl_annotate_read(handle: u32, start: u32, end: u32, ptr: u32, cap: u32) i32;
pub extern "weft" fn wl_annotate_begin(handle: u32) i32;
pub extern "weft" fn wl_annotate_span(handle: u32, start: u32, end: u32, role: u32, placement: u32, ptr: u32, len: u32) void;
// Native `editor` surface + anchored ranges. A range crosses as an opaque u32
// handle into a host-side table of document-owned anchors.
pub extern "weft" fn wl_editor_step(from: u32, dir: u32, kind: u32) u32;
pub extern "weft" fn wl_set_selection(start: u32, end: u32) void;
pub extern "weft" fn wl_anchor_range(start: u32, end: u32) i32;
pub extern "weft" fn wl_set_result_range(handle: u32) void;
pub extern "weft" fn wl_run_range(ptr: u32, len: u32) i32;
pub extern "weft" fn wl_range_ends(handle: u32, out_ptr: u32) i32;
pub extern "weft" fn wl_range_retain(handle: u32) i32;
pub extern "weft" fn wl_range_release(handle: u32) void;
pub extern "weft" fn wl_run_range_arg(ptr: u32, len: u32, handle: u32) void;
pub extern "weft" fn wl_arg_range(i: u32) i32;
pub extern "weft" fn wl_edit_range(handle: u32, ptr: u32, len: u32) void;
pub extern "weft" fn wl_kv_get(kptr: u32, klen: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_kv_put(kptr: u32, klen: u32, vptr: u32, vlen: u32) void;
pub extern "weft" fn wl_echo(ptr: u32, len: u32) void;
// Command args (readable during on_command) + result (set during it).
pub extern "weft" fn wl_arg_count() u32;
pub extern "weft" fn wl_arg_int(i: u32) i32;
pub extern "weft" fn wl_arg_str(i: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_set_result_int(n: i32) void;
pub extern "weft" fn wl_set_result_str(ptr: u32, len: u32) void;
// Config surface (the local plane — bindings/modes, as init.fnl did).
pub extern "weft" fn wl_bind_key(m: u32, ml: u32, k: u32, kl: u32, c: u32, cl: u32) void;
pub extern "weft" fn wl_bind_keys(m: u32, ml: u32, k: u32, kl: u32, list: u32, list_len: u32) void;
pub extern "weft" fn wl_set_mode(ptr: u32, len: u32) void;
pub extern "weft" fn wl_set_fallback(m: u32, ml: u32, par: u32, pl: u32) void;
pub extern "weft" fn wl_text_input(m: u32, ml: u32, c: u32, cl: u32, has: u32) void;
pub extern "weft" fn wl_menu_mode(ptr: u32, len: u32) void;
pub extern "weft" fn wl_resting_mode(ptr: u32, len: u32) void;
pub extern "weft" fn wl_exit_to_resting() void;
pub extern "weft" fn wl_resting_posture(posture: u32, ptr: u32, len: u32) void;
pub extern "weft" fn wl_posture() u32;
pub extern "weft" fn wl_declare_posture(posture: u32) void;
pub extern "weft" fn wl_provide(a: u32, al: u32, pred: u32, pred_len: u32, c: u32, cl: u32, prio: i32) void;
pub extern "weft" fn wl_sticky_menu(ptr: u32, len: u32) void;
pub extern "weft" fn wl_run(ptr: u32, len: u32) void;
pub extern "weft" fn wl_run_int(ptr: u32, len: u32, n: i32) void;
pub extern "weft" fn wl_run_str(ptr: u32, len: u32, s: u32, sl: u32) void;
pub extern "weft" fn wl_run_str2(ptr: u32, len: u32, a: u32, al: u32, b: u32, bl: u32) void;
pub extern "weft" fn wl_run_argv(ptr: u32, len: u32, vec: u32, argc: u32) void;
// Introspection (palettes/help/buffers pickers).
pub extern "weft" fn wl_command_count() u32;
pub extern "weft" fn wl_command_name(i: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_command_summary(i: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_command_arity(i: u32) i32;
pub extern "weft" fn wl_command_arity_required(i: u32) i32;
pub extern "weft" fn wl_command_arg(i: u32, k: u32, out_ptr: u32, out_cap: u32) i32;
// The focused context's live offers, and the door one is accepted through.
pub extern "weft" fn wl_offer_count() u32;
pub extern "weft" fn wl_offer_name(i: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_offer_provider(i: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_offer_reason(i: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_intent_invoke(ptr: u32, len: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_offers_begin(scope: u32, scope_len: u32, revision: u32) u32;
pub extern "weft" fn wl_offer(i: u32, il: u32, c: u32, cl: u32, r: u32, rl: u32) u32;
pub extern "weft" fn wl_offers_commit() u32;
pub extern "weft" fn wl_offers_retract() void;
pub extern "weft" fn wl_buffer_count() u32;
pub extern "weft" fn wl_buffer_id(i: u32) i32;
pub extern "weft" fn wl_buffer_name(i: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_buffer_active(i: u32) u32;
pub extern "weft" fn wl_mode_names(out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_binding_table(mode_ptr: u32, mode_len: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_buffer_readonly(i: u32) u32;
pub extern "weft" fn wl_buffer_path(i: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_buffer_dirty(i: u32) i32;
pub extern "weft" fn wl_buffer_lang(i: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_buffer_byte_len(i: u32) i32;
pub extern "weft" fn wl_buffer_tool(i: u32, out_ptr: u32, out_cap: u32) i32;
// Fuzzy pick (built incrementally, then opened; accept dispatches back to the
// guest's on_pick_accept export).
pub extern "weft" fn wl_pick_begin(prompt_ptr: u32, prompt_len: u32, pick_id: u32) void;
pub extern "weft" fn wl_pick_free_text(on: u32) void;
pub extern "weft" fn wl_pick_category(ptr: u32, len: u32) void;
pub extern "weft" fn wl_pick_add(t: u32, tl: u32, d: u32, dl: u32) void;
pub extern "weft" fn wl_pick_add_buffer(t: u32, tl: u32, d: u32, dl: u32, i: u32) void;
pub extern "weft" fn wl_pick_end() void;
pub extern "weft" fn wl_open_file_pick(prompt_ptr: u32, prompt_len: u32, root_ptr: u32, root_len: u32, pick_id: u32) void;
pub extern "weft" fn wl_pick_outcome_kind() i32;
pub extern "weft" fn wl_pick_outcome_text(out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_pick_outcome_query(out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_pick_outcome_index() i32;
pub extern "weft" fn wl_pick_outcome_buffer() i32;
pub extern "weft" fn wl_pick_outcome_match_start() i32;
pub extern "weft" fn wl_pick_outcome_match_span() i32;
pub extern "weft" fn wl_surface_begin(placement: u32) void;
pub extern "weft" fn wl_surface_caret(offset: u32) void;
pub extern "weft" fn wl_surface_row() void;
pub extern "weft" fn wl_surface_span(t: u32, tl: u32, role: u32) void;
pub extern "weft" fn wl_surface_end(selected: i32) void;
pub extern "weft" fn wl_surface_close() void;
pub extern "weft" fn wl_menu_binding_count() i32;
pub extern "weft" fn wl_menu_binding_key(i: u32, out: u32, cap: u32) i32;
pub extern "weft" fn wl_menu_binding_cmd(i: u32, out: u32, cap: u32) i32;
pub extern "weft" fn wl_menu_binding_is_group(i: u32) i32;
pub extern "weft" fn wl_menu_binding_intent_status(i: u32) i32;
pub extern "weft" fn wl_menu_binding_intent(i: u32, out: u32, cap: u32) i32;
pub extern "weft" fn wl_menu_binding_intent_note(i: u32, out: u32, cap: u32) i32;
pub extern "weft" fn wl_provide_completion() void;
pub extern "weft" fn wl_completion_prefix(out_ptr: u32, out_cap: u32) u32;
pub extern "weft" fn wl_caps_item(session: i32, t: u32, tl: u32, l: u32, ll: u32, d: u32, dl: u32, kind: i32, doc: u32, docl: u32, rank: i32) void;
pub extern "weft" fn wl_caps_commit(session: i32) void;
pub extern "weft" fn wl_caps_decline(session: i32) void;
// Structural (tree-sitter) read + subbuffers.
pub extern "weft" fn wl_node_at(offset: u32, kind_out: u32, kind_cap: u32, span_out: u32) i32;
pub extern "weft" fn wl_node_enclosing(start: u32, end: u32, kind_out: u32, kind_cap: u32, span_out: u32) i32;
pub extern "weft" fn wl_query(scm_ptr: u32, scm_len: u32, start: u32, end: u32) i32;
pub extern "weft" fn wl_query_capture(i: u32, name_out: u32, name_cap: u32, span_out: u32) i32;
pub extern "weft" fn wl_node_children(off: u32) i32;
pub extern "weft" fn wl_activate_path(out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_claim_subbuffer(start: u32, end: u32) i32;
pub extern "weft" fn wl_subbuffer_put_fact(handle: u32, k: u32, kl: u32, v: u32, vl: u32) void;
pub extern "weft" fn wl_tool_backing(ptr: u32, len: u32) void;
// Register/kill service (core, shared by every editor): yank snapshots text +
// any overlapping subbuffer facts; paste re-stamps them over inserted text.
pub extern "weft" fn wl_yank_range(start: u32, end: u32, linewise: u32, name: u32) void;
pub extern "weft" fn wl_register_text(out_ptr: u32, out_cap: u32, name: u32) u32;
pub extern "weft" fn wl_register_linewise(name: u32) u32;
pub extern "weft" fn wl_paste_at(base: u32, name: u32) void;
pub extern "weft" fn wl_semantic_view_focus(authority: u32, slot: u32, generation: u32, preferred_low: u32, preferred_high: u32, has_preferred: u32) i32;
pub extern "weft" fn wl_semantic_interaction_open(payload: u32, payload_len: u32, out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_interaction_close(authority: u32, slot: u32, generation: u32) u32;
pub extern "weft" fn wl_semantic_action(action: u32, action_len: u32, register: u32) i32;
pub extern "weft" fn wl_semantic_target_publish(payload: u32, payload_len: u32, out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_target_replace(authority: u32, slot: u32, generation: u32, payload: u32, payload_len: u32) i32;
pub extern "weft" fn wl_semantic_target_close(authority: u32, slot: u32, generation: u32) u32;
pub extern "weft" fn wl_semantic_target_describe_len(authority: u32, slot: u32, generation: u32) i32;
pub extern "weft" fn wl_semantic_target_describe(authority: u32, slot: u32, generation: u32, out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_view_publish(payload: u32, payload_len: u32, target_authority: u32, target_slot: u32, target_generation: u32, revision: u32, out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_view_replace(authority: u32, slot: u32, generation: u32, revision: u32, payload: u32, payload_len: u32) i32;
pub extern "weft" fn wl_semantic_view_close(authority: u32, slot: u32, generation: u32) u32;
pub extern "weft" fn wl_semantic_field_register(token: u32, revision: u32, revision_len: u32, bytes: u32, bytes_len: u32, anchor: u32, caret: u32, flags: u32, out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_field_update(authority: u32, slot: u32, generation: u32, revision: u32, revision_len: u32, bytes: u32, bytes_len: u32, anchor: u32, caret: u32, flags: u32) i32;
pub extern "weft" fn wl_semantic_field_close(authority: u32, slot: u32, generation: u32) u32;
pub extern "weft" fn wl_semantic_field_edit_meta(out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_field_edit_revision(out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_field_edit_replacement(out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_action_provider() i32;
pub extern "weft" fn wl_semantic_action_request_len() i32;
pub extern "weft" fn wl_semantic_action_request(out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_action_respond(kind: u32, payload: u32, payload_len: u32) i32;
// Synchronous target-handler callbacks. The host owns the registry and calls
// the guest's optional `on_semantic_target_probe/open` export. During those
// callbacks, the request imports expose one canonical descriptor/located
// target and the response imports accept exactly one scalar answer.
pub extern "weft" fn wl_semantic_target_handler_register(token: u32, id: u32, id_len: u32, out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_target_handler_close(authority: u32, slot: u32, generation: u32) u32;
pub extern "weft" fn wl_semantic_target_handler_request_len() i32;
pub extern "weft" fn wl_semantic_target_handler_request(out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_target_handler_probe_respond(kind: u32) i32;
pub extern "weft" fn wl_semantic_target_handler_open_respond(kind: u32, authority: u32, slot: u32, generation: u32) i32;
// Synchronous named-relation providers. A response carries only the located
// destination: the host retains the requested relation name and validates the
// returned target revision/location before admitting it.
pub extern "weft" fn wl_semantic_relation_provider_register(token: u32, id: u32, id_len: u32, out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_relation_provider_close(authority: u32, slot: u32, generation: u32) u32;
pub extern "weft" fn wl_semantic_relation_request_len() i32;
pub extern "weft" fn wl_semantic_relation_request(out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_relation_respond(kind: u32, payload: u32, payload_len: u32) i32;
pub extern "weft" fn wl_semantic_transfer_capture(target_authority: u32, target_slot: u32, target_generation: u32, revision_low: u32, revision_high: u32, source_root_authority: u32, source_root_slot: u32, source_root_generation: u32, source_ref_authority: u32, source_ref_slot: u32, source_ref_generation: u32, revision_ptr: u32, revision_len: u32, out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_shell_insert(ptr: u32, len: u32) void;
pub extern "weft" fn wl_repl_start(cmd: u32, cmd_len: u32, name: u32, name_len: u32) i32;
pub extern "weft" fn wl_repl_send(handle: u32, ptr: u32, len: u32) void;
pub extern "weft" fn wl_repl_quit(handle: u32) void;
pub extern "weft" fn wl_proc_spawn(cmd: u32, cmd_len: u32) i32;
pub extern "weft" fn wl_proc_send(handle: u32, ptr: u32, len: u32) void;
pub extern "weft" fn wl_proc_read(handle: u32, out: u32, cap: u32) i32;
pub extern "weft" fn wl_proc_close(handle: u32) void;
pub extern "weft" fn wl_place_root(out: u32, cap: u32) i32;
pub extern "weft" fn wl_place_id() i32;
pub extern "weft" fn wl_place_has(rel: u32, rel_len: u32) i32;
pub extern "weft" fn wl_env_publish(ptr: u32, len: u32) i32;
pub extern "weft" fn wl_net_connect(host: u32, host_len: u32, name: u32, name_len: u32, sni: u32, sni_len: u32) i32;
pub extern "weft" fn wl_net_send(handle: u32, ptr: u32, len: u32) void;
pub extern "weft" fn wl_net_close(handle: u32) void;
pub extern "weft" fn wl_proc_to_buffer(cmd: u32, cmd_len: u32, name: u32, name_len: u32, token: u32) void;
pub extern "weft" fn wl_proc_append_buffer(cmd: u32, cmd_len: u32, name: u32, name_len: u32, token: u32) void;
pub extern "weft" fn wl_proc_spool(cmd: u32, cmd_len: u32, input: u32, input_len: u32, name: u32, name_len: u32, token: u32) void;
pub extern "weft" fn wl_proc_filter(cmd: u32, cmd_len: u32, start: u32, end: u32) void;
pub extern "weft" fn wl_exec(argv: u32, argv_len: u32, argc: u32, input: u32, input_len: u32, at: u32, at_len: u32, token: u32) i32;
pub extern "weft" fn wl_exec_status() i32;
pub extern "weft" fn wl_exec_read(which: u32, offset: u32, out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_proj_begin(name: u32, name_len: u32) i32;
pub extern "weft" fn wl_proj_node(key: u32, key_len: u32, role: u32, role_len: u32, text: u32, text_len: u32, parent: i32, flags: u32, edit_start: i32, edit_end: i32) i32;
pub extern "weft" fn wl_proj_span(node: i32, start: i32, end: i32, role: u32, role_len: u32) void;
pub extern "weft" fn wl_proj_rows(out: u32, cap: u32) i32;
pub extern "weft" fn wl_proj_select(node: i32, start: i32, end: i32) void;
pub extern "weft" fn wl_proj_commit() i32;
pub extern "weft" fn wl_proj_at_cursor(out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_proj_toggle(key: u32, key_len: u32) i32;
pub extern "weft" fn wl_proj_selection(key: u32, key_len: u32, out: u32, out_cap: u32) i32;
pub extern "weft" fn wl_fs_read(path: u32, path_len: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_fs_exists(path: u32, path_len: u32) i32;
pub extern "weft" fn wl_fs_stat(path: u32, path_len: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_fs_write(path: u32, path_len: u32, ptr: u32, len: u32) i32;
pub extern "weft" fn wl_fs_append(path: u32, path_len: u32, ptr: u32, len: u32) i32;
pub extern "weft" fn wl_fs_list(auth: u32, auth_len: u32, path: u32, path_len: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_fs_publish_child_directory(request_ptr: u32, request_len: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_fs_publish_child_file(request_ptr: u32, request_len: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_fs_capabilities(target_authority: u32, target_slot: u32, target_generation: u32, revision_low: u32, revision_high: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_fs_list(target_authority: u32, target_slot: u32, target_generation: u32, revision_low: u32, revision_high: u32, out_ptr: u32, out_cap: u32) i32;
pub extern "weft" fn wl_semantic_fs_apply(target_authority: u32, target_slot: u32, target_generation: u32, revision_low: u32, revision_high: u32, plan_ptr: u32, plan_len: u32, out_ptr: u32, out_cap: u32) i32;
// D2's generic, schema-directed slot verbs (doc/d2-schema-payloads.md §3.2).
pub extern "weft" fn wl_slot_declare(name_ptr: u32, name_len: u32, shape: u32, composition: u32, schema_ptr: u32, schema_len: u32) void;
pub extern "weft" fn wl_slot_bind(name_ptr: u32, name_len: u32, pred_ptr: u32, pred_len: u32, tier: u32, priority: i32) void;
pub extern "weft" fn wl_payload_push(session: i32, version: u32, ptr: u32, len: u32) void;
pub extern "weft" fn wl_payload_read(session: i32, ptr: u32, cap: u32) i32;
pub extern "weft" fn wl_slot_fire(name_ptr: u32, name_len: u32, req_ptr: u32, req_len: u32) i32;
pub extern "weft" fn wl_slot_result_count(session: i32) i32;
pub extern "weft" fn wl_slot_done(session: i32) i32;
pub extern "weft" fn wl_slot_result(session: i32, index: u32, ptr: u32, cap: u32) i32;
pub extern "weft" fn wl_slot_result_provider(session: i32, index: u32, ptr: u32, cap: u32) i32;
pub extern "weft" fn wl_slot_finish(session: i32) void;

fn ZigType(comptime v: contract_data.ValType) type {
    return switch (v) {
        .i32 => i32,
        .u32 => u32,
    };
}

// The comptime tripwire the extern block's doc comment promises (task
// W0a-D): walk every `contract_data.imports` entry and confirm the
// hand-written extern of the same name, above, has the exact same arity
// AND per-param/result signedness. A drift — wrong count, `u32` where the
// table says `i32`, an extern renamed without updating the table, or a
// table entry with no matching extern at all — fails right here at
// compile time, pointing at the offending name, instead of silently
// desyncing the guest and host halves of the membrane again.
comptime {
    @setEvalBranchQuota(120_000); // n≈215 entries, each doing a small const-eval
    for (contract_data.imports) |entry| {
        const Fn = @typeInfo(@TypeOf(@field(@This(), entry.name))).@"fn";
        if (Fn.params.len != entry.params.len) @compileError(std.fmt.comptimePrint(
            "src/plugin_sdk/externs.zig: extern '{s}' takes {d} param(s), membrane/root.zig says {d}",
            .{ entry.name, Fn.params.len, entry.params.len },
        ));
        for (Fn.params, entry.params, 0..) |got, want, i| {
            if (got.type.? != ZigType(want)) @compileError(std.fmt.comptimePrint(
                "src/plugin_sdk/externs.zig: extern '{s}' param {d} type doesn't match membrane/root.zig's signedness",
                .{ entry.name, i },
            ));
        }
        const want_ret = if (entry.results.len == 0) void else ZigType(entry.results[0]);
        if (Fn.return_type.? != want_ret) @compileError(
            "src/plugin_sdk/externs.zig: extern '" ++ entry.name ++ "' return type doesn't match membrane/root.zig",
        );
    }
}

/// Config-table read. Declared with its siblings rather than beside the
/// decoder it feeds, so this file is the whole door list.
pub extern "weft" fn wl_config_get(kptr: u32, klen: u32, out_ptr: u32, out_cap: u32) i32;
