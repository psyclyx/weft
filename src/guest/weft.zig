//! weft.zig (guest side) — the ABI a `.wasm` plugin sees, mirroring the
//! in-process `abi.Abi` surface (src/core/abi.zig) one-for-one so the SAME
//! plugin logic reads identically whether it links in-process or crosses the
//! sandbox membrane. Only the transport differs: every call here is an
//! `extern "weft"` host import (the grant), scalars cross as i32/u32, and
//! bulk bytes cross through the guest's own linear memory — either the host
//! reads `(ptr, len)` out of us (writes: `edit`, `kvPut`) or fills a scratch
//! buffer we hand it `(ptr, cap)` and returns the length (reads: `slice`,
//! `kvGet`, `path`). No host pointer ever reaches the guest.
//!
//! Permission groups match abi.zig: A core (log), the describe-phase
//! declarations (declareCommand/requestPerm), B read-only (cursor/byteLen/
//! slice/lineAt/selection/path), C write (edit/register/jump), E admin (kv),
//! plus echo. A guest declares in `describe()`; the host cross-checks every
//! `register`/effect against that declaration (the perm handshake).

const std = @import("std");

/// A growable heap over the guest's wasm linear memory (grows via memory.grow).
/// Plugins that must hold data whose size the document dictates — a JSON-RPC
/// message, an escaped chunk — allocate here instead of a fixed buffer, so file
/// size is bounded by wasm memory (and streaming, for the unbounded cases), not
/// a compile-time constant. See [[completion-ux-roadmap]].
pub const allocator: std.mem.Allocator = std.heap.wasm_allocator;

/// The pure-data half of the membrane contract (core/membrane/
/// contract_data.zig) — no wasmtime/wasm_host dependency, so it compiles
/// here under wasm32-freestanding same as the host side does. Used below
/// ONLY by the comptime verification block; the ergonomic wrappers don't
/// reference it.
const contract_data = @import("membrane_contract_data");

/// D2's schema language + marshaller (core/schema.zig), imported under the
/// SAME name a guest's own code uses to reach it directly for a build-time-
/// known slot's typed encode/decode (§3.3's build-time codegen arm is a
/// LATER step; every guest today, including this SDK's own ergonomic
/// wrappers below, uses this module's runtime interpreter directly — the
/// §3.3 fallback arm, always available with zero codegen).
pub const schema = @import("weft_schema");

/// Portable semantic values and their canonical codec. These are named build
/// modules under the wasm target too: a plugin can author scenes and targets,
/// but cannot import host runtime implementation files sideways.
pub const semantic = @import("weft_semantic");
pub const semantic_codec = @import("weft_scene_codec");
pub const fs = @import("weft_fs");
pub const fs_codec = @import("weft_fs_codec");

// ── Raw host imports (the grants). Named `wl_*` to keep the ergonomic
// wrappers below as the surface guest code actually calls. Hand-written —
// Zig 0.16 can't synthesize an `extern fn` declaration from a comptime loop
// (no `@Type`, no `usingnamespace` decl-merging) — but comptime-VERIFIED
// against `contract_data.imports` below: an arity or signedness slip here,
// or an extern this file forgot to add/remove after the table changed,
// fails the BUILD (see the `comptime` block right after the extern list),
// not a silent runtime drift. ──
extern "weft" fn wl_log(level: u32, ptr: u32, len: u32) void;
extern "weft" fn wl_declare_command(ptr: u32, len: u32) void;
extern "weft" fn wl_declare_capability(ptr: u32, len: u32) void;
extern "weft" fn wl_request_perm(perm: u32) void;
extern "weft" fn wl_cursor() u32;
extern "weft" fn wl_byte_len() u32;
extern "weft" fn wl_doc_revision() u32;
extern "weft" fn wl_slice(start: u32, end: u32, out_ptr: u32, out_cap: u32) u32;
extern "weft" fn wl_line_at(offset: u32, out_ptr: u32) void;
extern "weft" fn wl_selection(out_ptr: u32) u32;
extern "weft" fn wl_path(out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_edit(start: u32, end: u32, ptr: u32, len: u32) void;
extern "weft" fn wl_render(start: u32, end: u32, ptr: u32, len: u32) void;
extern "weft" fn wl_edit_as(agent: u32, agent_len: u32, start: u32, end: u32, ptr: u32, len: u32) void;
extern "weft" fn wl_register(ptr: u32, len: u32) u32;
extern "weft" fn wl_jump(offset: u32) void;
extern "weft" fn wl_flash(start: u32, end: u32) void;
extern "weft" fn wl_style_clear() void;
extern "weft" fn wl_style(start: u32, end: u32, class: u32) void;
extern "weft" fn wl_fold_clear() void;
extern "weft" fn wl_fold(start: u32, end: u32) void;
extern "weft" fn wl_readonly_clear() void;
extern "weft" fn wl_readonly_span(start: u32, end: u32) void;
extern "weft" fn wl_decorate_clear() void;
extern "weft" fn wl_decorate(anchor: u32, placement: u32, role: u32, ptr: u32, len: u32) void;
extern "weft" fn wl_breakpoint_publish(path_ptr: u32, path_len: u32, csv_ptr: u32, csv_len: u32) void;
// Native `editor` surface + stamped ranges ([FIX 1/3]). A range crosses as an
// opaque u32 handle into a host-side table (the version token stays host-side).
extern "weft" fn wl_editor_step(from: u32, dir: u32, kind: u32) u32;
extern "weft" fn wl_set_selection(start: u32, end: u32) void;
extern "weft" fn wl_stamp_range(start: u32, end: u32) i32;
extern "weft" fn wl_set_result_range(handle: u32) void;
extern "weft" fn wl_run_range(ptr: u32, len: u32) i32;
extern "weft" fn wl_range_ends(handle: u32, out_ptr: u32) i32;
extern "weft" fn wl_run_range_arg(ptr: u32, len: u32, handle: u32) void;
extern "weft" fn wl_arg_range(i: u32) i32;
extern "weft" fn wl_edit_range(handle: u32, ptr: u32, len: u32) void;
extern "weft" fn wl_kv_get(kptr: u32, klen: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_kv_put(kptr: u32, klen: u32, vptr: u32, vlen: u32) void;
extern "weft" fn wl_echo(ptr: u32, len: u32) void;
// Command args (readable during on_command) + result (set during it).
extern "weft" fn wl_arg_count() u32;
extern "weft" fn wl_arg_int(i: u32) i32;
extern "weft" fn wl_arg_str(i: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_set_result_int(n: i32) void;
extern "weft" fn wl_set_result_str(ptr: u32, len: u32) void;
// Config surface (the local plane — bindings/modes, as init.fnl did).
extern "weft" fn wl_bind_key(m: u32, ml: u32, k: u32, kl: u32, c: u32, cl: u32) void;
extern "weft" fn wl_set_mode(ptr: u32, len: u32) void;
extern "weft" fn wl_set_fallback(m: u32, ml: u32, par: u32, pl: u32) void;
extern "weft" fn wl_text_input(m: u32, ml: u32, c: u32, cl: u32, has: u32) void;
extern "weft" fn wl_menu_mode(ptr: u32, len: u32) void;
extern "weft" fn wl_locked_mode(ptr: u32, len: u32) void;
extern "weft" fn wl_resting_mode(ptr: u32, len: u32) void;
extern "weft" fn wl_exit_to_resting() void;
extern "weft" fn wl_declare_action(ptr: u32, len: u32) void;
extern "weft" fn wl_provide(a: u32, al: u32, m: u32, ml: u32, l: u32, ll: u32, tl: u32, tll: u32, c: u32, cl: u32, prio: i32) void;
extern "weft" fn wl_sticky_menu(ptr: u32, len: u32) void;
extern "weft" fn wl_run(ptr: u32, len: u32) void;
extern "weft" fn wl_run_int(ptr: u32, len: u32, n: i32) void;
extern "weft" fn wl_run_str(ptr: u32, len: u32, s: u32, sl: u32) void;
extern "weft" fn wl_run_str2(ptr: u32, len: u32, a: u32, al: u32, b: u32, bl: u32) void;
// Introspection (palettes/help/buffers pickers).
extern "weft" fn wl_command_count() u32;
extern "weft" fn wl_command_name(i: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_command_summary(i: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_buffer_count() u32;
extern "weft" fn wl_buffer_id(i: u32) i32;
extern "weft" fn wl_buffer_name(i: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_buffer_active(i: u32) u32;
extern "weft" fn wl_buffer_readonly(i: u32) u32;
// Fuzzy pick (built incrementally, then opened; accept dispatches back to the
// guest's on_pick_accept export).
extern "weft" fn wl_pick_begin(prompt_ptr: u32, prompt_len: u32, pick_id: u32) void;
extern "weft" fn wl_pick_add(t: u32, tl: u32, d: u32, dl: u32) void;
extern "weft" fn wl_pick_end() void;
extern "weft" fn wl_open_file_pick(prompt_ptr: u32, prompt_len: u32, root_ptr: u32, root_len: u32, pick_id: u32) void;
extern "weft" fn wl_pick_choice(out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_pick_choice_index() i32;
extern "weft" fn wl_pick_choice_match_start() i32;
extern "weft" fn wl_surface_begin(placement: u32) void;
extern "weft" fn wl_surface_caret(offset: u32) void;
extern "weft" fn wl_surface_row() void;
extern "weft" fn wl_surface_span(t: u32, tl: u32, role: u32) void;
extern "weft" fn wl_surface_end(selected: i32) void;
extern "weft" fn wl_surface_close() void;
extern "weft" fn wl_menu_binding_count() i32;
extern "weft" fn wl_menu_binding_key(i: u32, out: u32, cap: u32) i32;
extern "weft" fn wl_menu_binding_cmd(i: u32, out: u32, cap: u32) i32;
extern "weft" fn wl_menu_binding_is_group(i: u32) i32;
extern "weft" fn wl_provide_completion() void;
extern "weft" fn wl_completion_prefix(out_ptr: u32, out_cap: u32) u32;
extern "weft" fn wl_caps_item(session: i32, t: u32, tl: u32, l: u32, ll: u32, d: u32, dl: u32, kind: i32, doc: u32, docl: u32, rank: i32) void;
extern "weft" fn wl_caps_commit(session: i32) void;
extern "weft" fn wl_caps_decline(session: i32) void;
// Structural (tree-sitter) read + subbuffers.
extern "weft" fn wl_node_at(offset: u32, kind_out: u32, kind_cap: u32, span_out: u32) i32;
extern "weft" fn wl_node_enclosing(start: u32, end: u32, kind_out: u32, kind_cap: u32, span_out: u32) i32;
extern "weft" fn wl_query(scm_ptr: u32, scm_len: u32, start: u32, end: u32) i32;
extern "weft" fn wl_query_capture(i: u32, name_out: u32, name_cap: u32, span_out: u32) i32;
extern "weft" fn wl_node_children(off: u32) i32;
extern "weft" fn wl_activate_path(out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_claim_subbuffer(start: u32, end: u32) i32;
extern "weft" fn wl_subbuffer_put_fact(handle: u32, k: u32, kl: u32, v: u32, vl: u32) void;
extern "weft" fn wl_subbuffer_clear() void;
extern "weft" fn wl_subbuffer_fact_at(offset: u32, k: u32, kl: u32, out: u32, cap: u32) i32;
extern "weft" fn wl_tool_backing(ptr: u32, len: u32) void;
// Register/kill service (core, shared by every editor): yank snapshots text +
// any overlapping subbuffer facts; paste re-stamps them over inserted text.
extern "weft" fn wl_yank_range(start: u32, end: u32, linewise: u32, name: u32) void;
extern "weft" fn wl_register_text(out_ptr: u32, out_cap: u32, name: u32) u32;
extern "weft" fn wl_register_linewise(name: u32) u32;
extern "weft" fn wl_paste_at(base: u32, name: u32) void;
extern "weft" fn wl_semantic_active() u32;
extern "weft" fn wl_semantic_working_target(out: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_view_focus(authority: u32, slot: u32, generation: u32, preferred_low: u32, preferred_high: u32, has_preferred: u32) i32;
extern "weft" fn wl_semantic_interaction_open(payload: u32, payload_len: u32, out: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_interaction_close(authority: u32, slot: u32, generation: u32) u32;
extern "weft" fn wl_semantic_action(action: u32, action_len: u32, register: u32) i32;
extern "weft" fn wl_semantic_target_publish(payload: u32, payload_len: u32, out: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_target_replace(authority: u32, slot: u32, generation: u32, payload: u32, payload_len: u32) i32;
extern "weft" fn wl_semantic_target_close(authority: u32, slot: u32, generation: u32) u32;
extern "weft" fn wl_semantic_target_describe_len(authority: u32, slot: u32, generation: u32) i32;
extern "weft" fn wl_semantic_target_describe(authority: u32, slot: u32, generation: u32, out: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_view_publish(payload: u32, payload_len: u32, target_authority: u32, target_slot: u32, target_generation: u32, revision: u32, out: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_view_replace(authority: u32, slot: u32, generation: u32, revision: u32, payload: u32, payload_len: u32) i32;
extern "weft" fn wl_semantic_view_close(authority: u32, slot: u32, generation: u32) u32;
extern "weft" fn wl_semantic_field_register(token: u32, revision: u32, revision_len: u32, bytes: u32, bytes_len: u32, anchor: u32, caret: u32, flags: u32, out: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_field_update(authority: u32, slot: u32, generation: u32, revision: u32, revision_len: u32, bytes: u32, bytes_len: u32, anchor: u32, caret: u32, flags: u32) i32;
extern "weft" fn wl_semantic_field_close(authority: u32, slot: u32, generation: u32) u32;
extern "weft" fn wl_semantic_field_edit_meta(out: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_field_edit_revision(out: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_field_edit_replacement(out: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_action_provider() i32;
extern "weft" fn wl_semantic_action_request_len() i32;
extern "weft" fn wl_semantic_action_request(out: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_action_respond(kind: u32, payload: u32, payload_len: u32) i32;
// Synchronous target-handler callbacks. The host owns the registry and calls
// the guest's optional `on_semantic_target_probe/open` export. During those
// callbacks, the request imports expose one canonical descriptor/located
// target and the response imports accept exactly one scalar answer.
extern "weft" fn wl_semantic_target_handler_register(token: u32, id: u32, id_len: u32, out: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_target_handler_close(authority: u32, slot: u32, generation: u32) u32;
extern "weft" fn wl_semantic_target_handler_request_len() i32;
extern "weft" fn wl_semantic_target_handler_request(out: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_target_handler_probe_respond(kind: u32) i32;
extern "weft" fn wl_semantic_target_handler_open_respond(kind: u32, authority: u32, slot: u32, generation: u32) i32;
// Synchronous named-relation providers. A response carries only the located
// destination: the host retains the requested relation name and validates the
// returned target revision/location before admitting it.
extern "weft" fn wl_semantic_relation_provider_register(token: u32, id: u32, id_len: u32, out: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_relation_provider_close(authority: u32, slot: u32, generation: u32) u32;
extern "weft" fn wl_semantic_relation_request_len() i32;
extern "weft" fn wl_semantic_relation_request(out: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_relation_respond(kind: u32, payload: u32, payload_len: u32) i32;
extern "weft" fn wl_semantic_transfer_capture(target_authority: u32, target_slot: u32, target_generation: u32, revision_low: u32, revision_high: u32, source_root_authority: u32, source_root_slot: u32, source_root_generation: u32, source_ref_authority: u32, source_ref_slot: u32, source_ref_generation: u32, revision_ptr: u32, revision_len: u32, out: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_transfer_retain(authority: u32, slot: u32, generation: u32) i32;
extern "weft" fn wl_semantic_transfer_release(authority: u32, slot: u32, generation: u32) i32;
extern "weft" fn wl_shell_insert(ptr: u32, len: u32) void;
extern "weft" fn wl_repl_start(cmd: u32, cmd_len: u32, name: u32, name_len: u32) i32;
extern "weft" fn wl_repl_send(handle: u32, ptr: u32, len: u32) void;
extern "weft" fn wl_repl_quit(handle: u32) void;
extern "weft" fn wl_proc_spawn(cmd: u32, cmd_len: u32) i32;
extern "weft" fn wl_proc_send(handle: u32, ptr: u32, len: u32) void;
extern "weft" fn wl_proc_read(handle: u32, out: u32, cap: u32) i32;
extern "weft" fn wl_proc_close(handle: u32) void;
extern "weft" fn wl_cwd(out: u32, cap: u32) i32;
extern "weft" fn wl_net_connect(host: u32, host_len: u32, name: u32, name_len: u32, sni: u32, sni_len: u32) i32;
extern "weft" fn wl_net_send(handle: u32, ptr: u32, len: u32) void;
extern "weft" fn wl_net_close(handle: u32) void;
extern "weft" fn wl_proc_to_buffer(cmd: u32, cmd_len: u32, name: u32, name_len: u32) void;
extern "weft" fn wl_proc_append_buffer(cmd: u32, cmd_len: u32, name: u32, name_len: u32) void;
extern "weft" fn wl_proc_filter(cmd: u32, cmd_len: u32, start: u32, end: u32) void;
extern "weft" fn wl_fs_read(path: u32, path_len: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_fs_exists(path: u32, path_len: u32) i32;
extern "weft" fn wl_fs_write(path: u32, path_len: u32, ptr: u32, len: u32) i32;
extern "weft" fn wl_fs_append(path: u32, path_len: u32, ptr: u32, len: u32) i32;
extern "weft" fn wl_fs_list(auth: u32, auth_len: u32, path: u32, path_len: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_fs_list_async(auth: u32, auth_len: u32, path: u32, path_len: u32, dest: u32, dest_len: u32) i32;
extern "weft" fn wl_semantic_fs_publish_child_directory(request_ptr: u32, request_len: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_fs_publish_child_file(request_ptr: u32, request_len: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_fs_capabilities(target_authority: u32, target_slot: u32, target_generation: u32, revision_low: u32, revision_high: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_fs_list(target_authority: u32, target_slot: u32, target_generation: u32, revision_low: u32, revision_high: u32, out_ptr: u32, out_cap: u32) i32;
extern "weft" fn wl_semantic_fs_apply(target_authority: u32, target_slot: u32, target_generation: u32, revision_low: u32, revision_high: u32, plan_ptr: u32, plan_len: u32, out_ptr: u32, out_cap: u32) i32;
// D2's generic, schema-directed slot verbs (doc/d2-schema-payloads.md §3.2).
extern "weft" fn wl_slot_declare(name_ptr: u32, name_len: u32, shape: u32, composition: u32, schema_ptr: u32, schema_len: u32) void;
extern "weft" fn wl_slot_bind(name_ptr: u32, name_len: u32, pred_ptr: u32, pred_len: u32, tier: u32, priority: i32) void;
extern "weft" fn wl_payload_push(session: i32, version: u32, ptr: u32, len: u32) void;
extern "weft" fn wl_payload_read(session: i32, ptr: u32, cap: u32) i32;

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
    @setEvalBranchQuota(50_000); // n≈130 entries, each doing a small const-eval
    for (contract_data.imports) |entry| {
        const Fn = @typeInfo(@TypeOf(@field(@This(), entry.name))).@"fn";
        if (Fn.params.len != entry.params.len) @compileError(std.fmt.comptimePrint(
            "src/guest/weft.zig: extern '{s}' takes {d} param(s), contract_data.zig says {d}",
            .{ entry.name, Fn.params.len, entry.params.len },
        ));
        for (Fn.params, entry.params, 0..) |got, want, i| {
            if (got.type.? != ZigType(want)) @compileError(std.fmt.comptimePrint(
                "src/guest/weft.zig: extern '{s}' param {d} type doesn't match contract_data.zig's signedness",
                .{ entry.name, i },
            ));
        }
        const want_ret = if (entry.results.len == 0) void else ZigType(entry.results[0]);
        if (Fn.return_type.? != want_ret) @compileError(
            "src/guest/weft.zig: extern '" ++ entry.name ++ "' return type doesn't match contract_data.zig",
        );
    }
}

/// Shared scratch for host→guest byte returns. A read wrapper (`slice`,
/// `path`, `kvGet`) returns a slice INTO this buffer, valid until the next
/// read call — copy what must outlive that. 64 KiB covers a line/value; the
/// host truncates to `cap`, so an over-long read is clamped, never a
/// buffer overrun.
var scratch: [1 << 16]u8 = undefined;
/// A separate scratch for `completionPrefix`, so a provider can hold its
/// prefix while it walks the buffer through `slice` (which reuses `scratch`).
var prefix_scratch: [1 << 12]u8 = undefined;
/// A separate scratch for command-arg strings, so a handler can hold an arg
/// while it reads the buffer through `slice`.
var arg_scratch: [1 << 12]u8 = undefined;

fn p(x: anytype) u32 {
    return @intCast(@intFromPtr(x));
}

pub const Range = struct { start: usize, end: usize };
pub const Level = enum(u32) { debug = 0, info = 1, warn = 2, err = 3 };
/// Mirrors abi.Perm's order (fs_read, fs_write, net, proc, timer).
pub const Perm = enum(u32) { fs_read = 0, fs_write = 1, net = 2, proc = 3, timer = 4 };

// ── Group A: core ────────────────────────────────────────────────────
pub fn log(level: Level, msg: []const u8) void {
    wl_log(@intFromEnum(level), p(msg.ptr), @intCast(msg.len));
}

// ── Describe phase: up-front declarations (no authority) ──────────────
pub fn declareCommand(name: []const u8) void {
    wl_declare_command(p(name.ptr), @intCast(name.len));
}
/// Declare a capability this plugin will provide (e.g. "edit/completion").
/// Cross-checked host-side against the matching `provide*` at init time.
pub fn declareCapability(name: []const u8) void {
    wl_declare_capability(p(name.ptr), @intCast(name.len));
}
pub fn requestPerm(perm: Perm) void {
    wl_request_perm(@intFromEnum(perm));
}

// ── Group B: read-only ───────────────────────────────────────────────
pub fn cursor() usize {
    return wl_cursor();
}
pub fn byteLen() usize {
    return wl_byte_len();
}
/// The active document's monotonic commit count — a cheap change token (bumps on
/// every edit). Track it to know when to resync without diffing the text.
pub fn docRevision() u32 {
    return wl_doc_revision();
}
/// Bytes of `[start, end)` of the active document (clamped). Valid until the
/// next read call — copy to keep.
pub fn slice(start: usize, end: usize) []const u8 {
    const n = wl_slice(@intCast(start), @intCast(end), p(&scratch), scratch.len);
    return scratch[0..n];
}
/// `[start, end)` of the line containing `offset` (end before the newline).
pub fn lineAt(offset: usize) Range {
    var pair: [2]u32 = undefined;
    wl_line_at(@intCast(offset), p(&pair));
    return .{ .start = pair[0], .end = pair[1] };
}
/// The current selection range, or null.
pub fn selection() ?Range {
    var pair: [2]u32 = undefined;
    if (wl_selection(p(&pair)) == 0) return null;
    return .{ .start = pair[0], .end = pair[1] };
}
/// The active buffer's backing path, or null. Valid until the next read call.
pub fn path() ?[]const u8 {
    const n = wl_path(p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}

// ── Group C: write (grade-gated host-side by the plugin's principal) ──
/// THE text-mutation door: replace `[r.start, r.end)` with `bytes`, authored
/// as this plugin's peer through the host's grade gate.
pub fn edit(r: Range, bytes: []const u8) void {
    wl_edit(@intCast(r.start), @intCast(r.end), p(bytes.ptr), @intCast(bytes.len));
}
/// CONTENT PRODUCTION door: draw a derived/streamed projection (a tool buffer's
/// listing, a transcript) into `[r.start, r.end)`. Distinct from `edit`: it
/// BYPASSES read-only (the text is output, regenerated from a model — not
/// user-editable) and authors as the plugin's own peer (not the user's undo).
/// Tool/model buffers render with this; `edit` is for interactive text.
pub fn render(r: Range, bytes: []const u8) void {
    wl_render(@intCast(r.start), @intCast(r.end), p(bytes.ptr), @intCast(bytes.len));
}
/// Like `edit`, but authored as the named `role=.agent` sub-peer `agent`
/// (e.g. "claude", "codex") instead of this plugin's own peer — so an agent
/// plugin's edits attribute per-agent and get their own selective-undo unit.
/// An empty `agent` falls back to the plugin peer. Grade-gated identically.
pub fn editAs(agent: []const u8, r: Range, bytes: []const u8) void {
    wl_edit_as(p(agent.ptr), @intCast(agent.len), @intCast(r.start), @intCast(r.end), p(bytes.ptr), @intCast(bytes.len));
}
/// Register a command (cross-checked against `describe`). Returns its id, the
/// value the host passes back to `on_command`.
pub fn register(name: []const u8) u32 {
    return wl_register(p(name.ptr), @intCast(name.len));
}
/// Place the live cursor at a byte offset (clamped).
pub fn jump(offset: usize) void {
    wl_jump(@intCast(offset));
}
/// vim-goggles: briefly flash the byte range `[start, end)` (e.g. the region a
/// yank just copied), a visual confirmation of what an operator affected.
pub fn flash(start: usize, end: usize) void {
    wl_flash(@intCast(start), @intCast(end));
}

// ── Styles (tool-buffer coloring): publish per-byte-range StyleClass spans over
// the ACTIVE buffer, painted by the view through the theme (same door as
// `edit` for which buffer it targets). `styleClear` first, then a `style` per
// classified range — the classic magit/grep coloring pattern. Cleared with the
// buffer on close. Mirrors core.capability.StyleClass. ──
pub const StyleClass = enum(u32) {
    normal = 0,
    added = 1,
    removed = 2,
    header = 3,
    location = 4,
    emphasis = 5,
    muted = 6,
};

/// Drop the active buffer's style spans and re-baseline them to `.normal` over
/// the whole buffer — call before repopulating with `style`.
pub fn styleClear() void {
    wl_style_clear();
}
/// Paint `[start, end)` of the active buffer with `class` (clamped to the buffer;
/// a no-op if `styleClear` wasn't called first this round).
pub fn style(start: usize, end: usize, class: StyleClass) void {
    wl_style(@intCast(start), @intCast(end), @intFromEnum(class));
}

// ── Folding: hide byte ranges of the active buffer (rows collapse; vertical
// motion skips them). A general primitive — status/dired/grep/outline plugins
// fold sections. `foldClear` then a `fold` per hidden range; republish on every
// re-render (offsets move). `start` should be just past a header line's newline
// so the header stays visible. ──
pub fn foldClear() void {
    wl_fold_clear();
}
/// Hide `[start, end)` — collapse those rows until the next `foldClear`.
pub fn fold(start: usize, end: usize) void {
    wl_fold(@intCast(start), @intCast(end));
}
/// Reclaim + empty the read-only-span layer (republish the full set after).
pub fn readOnlyClear() void {
    wl_readonly_clear();
}
/// Mark `[start, end)` read-only: an interactive edit overlapping it is refused
/// at the edit door (a comint's produced output vs its editable input line).
pub fn readOnlySpan(start: usize, end: usize) void {
    wl_readonly_span(@intCast(start), @intCast(end));
}

/// How a decoration is placed beside the text (never in the document).
pub const DecoPlacement = enum(u32) { virtual_before = 1, virtual_after = 2, eol = 3, gutter = 4 };
/// Reclaim + empty the decorations layer (republish the full set after).
pub fn decorateClear() void {
    wl_decorate_clear();
}
/// Place a display-only decoration anchored at `anchor`: virtual text drawn
/// beside the line, colored by `role` (a styles-palette class). It is NEVER a
/// document byte — so `yy` never yanks it and it takes no commit. This is how a
/// projection shows metadata (dired's perms/size/arrow/mark) off the text.
pub fn decorate(anchor: usize, placement: DecoPlacement, role: StyleClass, text: []const u8) void {
    wl_decorate(@intCast(anchor), @intFromEnum(placement), @intFromEnum(role), p(text.ptr), @intCast(text.len));
}

/// Publish this buffer's breakpoint lines (a "l1,l2,…" CSV) to the shared
/// registry, so the DAP client can send them in setBreakpoints. The `debug`
/// plugin calls this whenever the set changes.
pub fn publishBreakpoints(file: []const u8, line_csv: []const u8) void {
    wl_breakpoint_publish(p(file.ptr), @intCast(file.len), p(line_csv.ptr), @intCast(line_csv.len));
}

// ── Native editor surface + stamped ranges (motions/operators) ────────
pub const Dir = enum(u32) { back = 0, fwd = 1 };
pub const Kind = enum(u32) { char = 0, line = 1 };

/// The target offset one char (grapheme) or line from `from` in `dir`, without
/// moving the cursor. The native primitive a motion composes (design §6.1).
pub fn step(from: usize, dir: Dir, kind: Kind) usize {
    return wl_editor_step(@intCast(from), @intFromEnum(dir), @intFromEnum(kind));
}
/// Select `[r.start, r.end)` (mark at start, cursor at end).
pub fn setSelection(r: Range) void {
    wl_set_selection(@intCast(r.start), @intCast(r.end));
}

/// Stamp `[r.start, r.end)` at the current version → an opaque range handle
/// (valid for this dispatch), or null on failure. The one way to build a range.
pub fn stampRange(r: Range) ?u32 {
    const h = wl_stamp_range(@intCast(r.start), @intCast(r.end));
    return if (h < 0) null else @intCast(h);
}
/// Return the stamped range `handle` as this command's result (the motion
/// contract): an operator awaiting it via `runRange` gets a version-stamped
/// range, never a bare offset.
pub fn setResultRange(handle: u32) void {
    wl_set_result_range(handle);
}
/// Run `cmd` (a motion) and take its returned range as an opaque handle, or
/// null if it produced none. The handle is valid for the rest of this dispatch.
pub fn runRange(cmd: []const u8) ?u32 {
    const h = wl_run_range(p(cmd.ptr), @intCast(cmd.len));
    return if (h < 0) null else @intCast(h);
}
/// Resolve a range handle to its current `[start, end)`, or null if stale.
pub fn rangeEnds(handle: u32) ?Range {
    var pair: [2]u32 = undefined;
    if (wl_range_ends(handle, p(&pair)) < 0) return null;
    return .{ .start = pair[0], .end = pair[1] };
}
/// Run `cmd` (an operator) passing a range `handle` as its single arg.
pub fn runRangeArg(cmd: []const u8, handle: u32) void {
    wl_run_range_arg(p(cmd.ptr), @intCast(cmd.len), handle);
}
/// The `i`-th arg as a stamped-range handle, or null if it is not a range.
pub fn argRange(i: usize) ?u32 {
    const h = wl_arg_range(@intCast(i));
    return if (h < 0) null else @intCast(h);
}
/// Replace the stamped range `handle` with `bytes`, authored as this plugin's
/// peer through the grade gate (rebased to head first).
pub fn editRange(handle: u32, bytes: []const u8) void {
    wl_edit_range(handle, p(bytes.ptr), @intCast(bytes.len));
}

// ── Group E: admin (kv) ──────────────────────────────────────────────
/// This plugin's value for `key` (namespaced host-side), or null. Valid until
/// the next read call.
pub fn kvGet(key: []const u8) ?[]const u8 {
    const n = wl_kv_get(p(key.ptr), @intCast(key.len), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}
pub fn kvPut(key: []const u8, value: []const u8) void {
    wl_kv_put(p(key.ptr), @intCast(key.len), p(value.ptr), @intCast(value.len));
}

// ── Config data (weft.set): declarative tables that override a plugin's
// shipped defaults; read at init. Uses a DEDICATED buffer (never the shared
// `scratch`), so a plugin can hold its decoded config while walking the buffer
// via `slice`/`kvGet`. Framed as uvarint(count) then count×(uvarint(len) ++
// bytes) — the same LEB128 style the shim encodes; the decoder returns null on
// a short/truncated buffer rather than silently dropping tail records. ──
var config_scratch: [1 << 16]u8 = undefined;
extern "weft" fn wl_config_get(kptr: u32, klen: u32, out_ptr: u32, out_cap: u32) i32;

fn getUv(cur: *[]const u8) ?u64 {
    var shift: u6 = 0;
    var v: u64 = 0;
    while (cur.len > 0) {
        const b = cur.*[0];
        cur.* = cur.*[1..];
        v |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return v;
        if (shift >= 57) return null;
        shift += 7;
    }
    return null;
}

/// Iterates the records of a config list. `next` returns null when exhausted,
/// or on a malformed/truncated buffer (so a short read never yields a partial
/// record silently).
pub const ConfigIter = struct {
    cur: []const u8,
    remaining: u64,
    pub fn next(self: *ConfigIter) ?[]const u8 {
        if (self.remaining == 0) return null;
        const n = getUv(&self.cur) orelse {
            self.remaining = 0;
            return null;
        };
        if (n > self.cur.len) {
            self.remaining = 0;
            return null;
        }
        const rec = self.cur[0..@intCast(n)];
        self.cur = self.cur[@intCast(n)..];
        self.remaining -= 1;
        return rec;
    }
};

/// This plugin's config list for `key` (from `weft.set`), or null if unset. The
/// iterator borrows `config_scratch` — valid until the next config read; safe
/// to hold across `slice`/`kvGet` (its own buffer).
pub fn configList(key: []const u8) ?ConfigIter {
    const n = wl_config_get(p(key.ptr), @intCast(key.len), p(&config_scratch), config_scratch.len);
    if (n < 0) return null;
    var cur: []const u8 = config_scratch[0..@intCast(n)];
    const count = getUv(&cur) orelse return null;
    return .{ .cur = cur, .remaining = count };
}

/// This plugin's single config value for `key` (the first record of its list),
/// or "" if unset. Borrows `config_scratch` — valid until the next config read.
pub fn config(key: []const u8) []const u8 {
    var it = configList(key) orelse return "";
    return it.next() orelse "";
}

/// Show a transient status-line message.
pub fn echo(msg: []const u8) void {
    wl_echo(p(msg.ptr), @intCast(msg.len));
}

// ── Command args & result (valid only during an `on_command` call) ────
// Integers cross as i32 — the membrane's word, the same width the offset ABI
// (cursor/edit/slice) already uses. Command Values wider than i32 are outside
// the sandbox contract (no catalog command passes one).

/// Number of args the command was invoked with.
pub fn argCount() usize {
    return wl_arg_count();
}
/// The `i`-th arg as an integer (0 if absent or not an integer).
pub fn argInt(i: usize) i32 {
    return wl_arg_int(@intCast(i));
}
/// The `i`-th arg as a string, or null if absent / not a string. Valid until
/// the next arg read (its own scratch — safe to hold across `slice`).
pub fn argStr(i: usize) ?[]const u8 {
    const n = wl_arg_str(@intCast(i), p(&arg_scratch), arg_scratch.len);
    if (n < 0) return null;
    return arg_scratch[0..@intCast(n)];
}
/// Set the command's integer return value.
pub fn setResultInt(n: i32) void {
    wl_set_result_int(n);
}
/// Set the command's string return value (copied host-side).
pub fn setResultStr(s: []const u8) void {
    wl_set_result_str(p(s.ptr), @intCast(s.len));
}

// ── Config surface (the local plane) ─────────────────────────────────
/// Bind `key` in keymap `mode` to `cmd` (late-bound; resolves at keypress).
pub fn bindKey(mode: []const u8, key: []const u8, cmd: []const u8) void {
    wl_bind_key(p(mode.ptr), @intCast(mode.len), p(key.ptr), @intCast(key.len), p(cmd.ptr), @intCast(cmd.len));
}
/// Switch the active keymap mode.
pub fn setMode(mode: []const u8) void {
    wl_set_mode(p(mode.ptr), @intCast(mode.len));
}
/// `mode` falls back to `parent` for unbound keys (mode inheritance).
pub fn setFallback(mode: []const u8, parent: []const u8) void {
    wl_set_fallback(p(mode.ptr), @intCast(mode.len), p(parent.ptr), @intCast(parent.len));
}
/// Set (or clear, with null) the command unbound printable input runs in
/// `mode` — the modal posture (normal mode swallows text).
pub fn textInput(mode: []const u8, cmd: ?[]const u8) void {
    if (cmd) |c| {
        wl_text_input(p(mode.ptr), @intCast(mode.len), p(c.ptr), @intCast(c.len), 1);
    } else {
        wl_text_input(p(mode.ptr), @intCast(mode.len), 0, 0, 0);
    }
}
/// Declare `mode` a menu/prefix mode (which-key shows its bindings).
pub fn menuMode(mode: []const u8) void {
    wl_menu_mode(p(mode.ptr), @intCast(mode.len));
}
/// Declare `mode` a LOCKED projection mode: a read-only view (magit, a git diff/
/// log) whose keymap is pinned — a `setMode` out of it is refused unless it
/// targets a menu or the same mode, so you can never end up in a generic editing
/// mode (`normal`) inside the projection. The framework enforces it; the plugin
/// just declares it (one line), never defensively handles the wrong-mode case.
pub fn lockedMode(mode: []const u8) void {
    wl_locked_mode(p(mode.ptr), @intCast(mode.len));
}
/// Declare `mode` a RESTING mode — the base a buffer settles in: the editing base
/// (`normal`) or a tool projection (`dired`, `output`, …). Leaving a buffer in a
/// transient sub-mode (visual/insert) remembers this instead of overshooting to
/// the root, so switching back doesn't strand you in an editing-less mode.
pub fn restingMode(mode: []const u8) void {
    wl_resting_mode(p(mode.ptr), @intCast(mode.len));
}
/// Leave a transient mode (insert/visual) back to the active buffer's RESTING
/// mode — its tool mode (dired) if any, else the editing base. Use on Escape
/// instead of a hardcoded `setMode("normal")`, so a projection's keys stay live.
pub fn exitToResting() void {
    wl_exit_to_resting();
}
/// Declare `mode` a STICKY menu: stays open after a leaf key (flag-accumulating
/// transients) instead of one-shot auto-popping. Implies `menuMode`.
pub fn stickyMenu(mode: []const u8) void {
    wl_sticky_menu(p(mode.ptr), @intCast(mode.len));
}

/// A provider's context predicate — the ambient facts that must hold for it to
/// win. An absent field is "don't care". Mirrors core.action.When.
pub const When = struct {
    /// Keymap mode that must be active.
    mode: ?[]const u8 = null,
    /// Buffer language — the active buffer name's extension (`zig`, `py`).
    lang: ?[]const u8 = null,
    /// The active buffer's tool-backing name (a plugin projection: `dired`) —
    /// a stable per-buffer signal, unlike `mode`. A projection scopes its
    /// `save`/etc. providers by this so they win in its buffer in any mode.
    tool: ?[]const u8 = null,
};

/// Declare an abstract intent `name` a key can bind to (and register its
/// trampoline command). Providers registered with `provide` resolve it by
/// context at fire time — the synthetic bind. Late-bound like `declareCommand`.
pub fn declareAction(name: []const u8) void {
    wl_declare_action(p(name.ptr), @intCast(name.len));
}

/// Register `cmd` as a provider for `action` under the predicate `when`, at
/// `prio` (higher wins; ties break toward the more specific `when`). Auto-
/// declares the action if `declareAction` hasn't run — a language plugin can
/// `provide("eval", .{ .lang = "zig" }, "zig-eval", 0)` and the key bound to
/// `eval` dispatches here in a .zig buffer, for free.
pub fn provide(action: []const u8, when: When, cmd: []const u8, prio: i32) void {
    const m = when.mode orelse "";
    const l = when.lang orelse "";
    const tl = when.tool orelse "";
    wl_provide(
        p(action.ptr),
        @intCast(action.len),
        p(m.ptr),
        @intCast(m.len),
        p(l.ptr),
        @intCast(l.len),
        p(tl.ptr),
        @intCast(tl.len),
        p(cmd.ptr),
        @intCast(cmd.len),
        prio,
    );
}
/// Invoke a command by name (no args), late-bound.
pub fn run(cmd: []const u8) void {
    wl_run(p(cmd.ptr), @intCast(cmd.len));
}
/// Invoke `cmd` with a single integer arg (e.g. buffer-switch).
pub fn runInt(cmd: []const u8, n: i32) void {
    wl_run_int(p(cmd.ptr), @intCast(cmd.len), n);
}
/// Invoke `cmd` with a single string arg (e.g. open <path>).
pub fn runStr(cmd: []const u8, s: []const u8) void {
    wl_run_str(p(cmd.ptr), @intCast(cmd.len), p(s.ptr), @intCast(s.len));
}
/// Invoke `cmd` with two string args (e.g. set-cursor <mode> <style>).
pub fn runStr2(cmd: []const u8, a: []const u8, b: []const u8) void {
    wl_run_str2(p(cmd.ptr), @intCast(cmd.len), p(a.ptr), @intCast(a.len), p(b.ptr), @intCast(b.len));
}

// ── Introspection (palettes/help/buffers) ────────────────────────────
pub fn commandCount() usize {
    return wl_command_count();
}
/// The `i`-th command's name (into `scratch`), or null for an empty slot.
pub fn commandName(i: usize) ?[]const u8 {
    const n = wl_command_name(@intCast(i), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}
/// The `i`-th command's summary (into `arg_scratch`, so it survives a paired
/// `commandName` read), or null.
pub fn commandSummary(i: usize) ?[]const u8 {
    const n = wl_command_summary(@intCast(i), p(&arg_scratch), arg_scratch.len);
    if (n < 0) return null;
    return arg_scratch[0..@intCast(n)];
}
pub fn bufferCount() usize {
    return wl_buffer_count();
}
pub fn bufferId(i: usize) ?i32 {
    const id = wl_buffer_id(@intCast(i));
    return if (id < 0) null else id;
}
pub fn bufferName(i: usize) ?[]const u8 {
    const n = wl_buffer_name(@intCast(i), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}
pub fn bufferActive(i: usize) bool {
    return wl_buffer_active(@intCast(i)) != 0;
}
pub fn bufferReadOnly(i: usize) bool {
    return wl_buffer_readonly(@intCast(i)) != 0;
}

// ── Fuzzy pick (open one incrementally; accept → on_pick_accept) ──────
/// Begin a pick with `prompt`; `pick_id` is the guest's tag for its accept
/// logic (dispatched to `on_pick_accept`).
pub fn pickBegin(prompt: []const u8, pick_id: u32) void {
    wl_pick_begin(p(prompt.ptr), @intCast(prompt.len), pick_id);
}
/// Add one item: `text` matches/accepts, `doc` is display-only.
pub fn pickAdd(text: []const u8, doc: []const u8) void {
    wl_pick_add(p(text.ptr), @intCast(text.len), p(doc.ptr), @intCast(doc.len));
}
/// Open the accumulated pick.
pub fn pickEnd() void {
    wl_pick_end();
}
/// Open a fuzzy FILE picker rooted at `root` (native recursive finder);
/// accept dispatches to `on_pick_accept` with the chosen path.
pub fn openFilePick(prompt: []const u8, root: []const u8, pick_id: u32) void {
    wl_open_file_pick(p(prompt.ptr), @intCast(prompt.len), p(root.ptr), @intCast(root.len), pick_id);
}

// ── Surface (retained overlay: build begin→row→span…→end, then close) ────
/// Where a surface docks. Mirrors core.surface.Placement. `caret` is begun
/// through `surfaceCaret`, not `surfaceBegin` — see its doc.
pub const Placement = enum(u32) { bottom = 0, corner = 1, center = 2, caret = 3 };
/// A span's semantic color role. Mirrors core.surface.Role — the theme resolves
/// each to a real color, so a colorscheme restyles the surface for free.
/// `annotation` is a dimmed side note (rendering P2 — see doc/rendering.md).
pub const Role = enum(u32) { normal = 0, accent = 1, group = 2, leaf = 3, effect = 4, muted = 5, annotation = 6 };

/// Begin (re)building this plugin's overlay at `placement` (`bottom`/
/// `corner`/`center` — a `caret` popup begins with `surfaceCaret` instead,
/// since it also needs the anchor offset). Not shown until `surfaceEnd`; the
/// previously-drawn surface stays live until then.
pub fn surfaceBegin(placement: Placement) void {
    wl_surface_begin(@intFromEnum(placement));
}
/// Begin (re)building a CARET-anchored overlay — placed at `offset` (a
/// document byte offset) instead of a corner/center/bottom dock; core lays
/// it out just below (or, flipped, above) the caret's screen line, clamped
/// into the viewport. The `lsp` plugin's hover popup uses this so its box
/// tracks the caret, the same generic `drawCaretSurface` renderer the
/// picker's own completion list draws through (rendering P2 — see
/// doc/rendering.md).
pub fn surfaceCaret(offset: usize) void {
    wl_surface_caret(@intCast(offset));
}
/// Start a new row.
pub fn surfaceRow() void {
    wl_surface_row();
}
/// Append a styled span to the current row.
pub fn surfaceSpan(text: []const u8, role: Role) void {
    wl_surface_span(p(text.ptr), @intCast(text.len), @intFromEnum(role));
}
/// Commit the built rows and show the surface. `selected` highlights a row
/// (a picker/dired cursor), or -1 for none.
pub fn surfaceEnd(selected: i32) void {
    wl_surface_end(selected);
}
/// Hide the surface (done with it).
pub fn surfaceClose() void {
    wl_surface_close();
}

// ── Menu bindings (for a which-key-style overlay): enumerate the CURRENT menu
// mode's table. Valid during on_menu(open). key → scratch, cmd → arg_scratch,
// so a caller can hold both of one binding at once. ──
pub fn menuBindingCount() usize {
    const n = wl_menu_binding_count();
    return if (n < 0) 0 else @intCast(n);
}
pub fn menuBindingKey(i: usize) []const u8 {
    const n = wl_menu_binding_key(@intCast(i), p(&scratch), scratch.len);
    return if (n < 0) "" else scratch[0..@intCast(n)];
}
pub fn menuBindingCmd(i: usize) []const u8 {
    const n = wl_menu_binding_cmd(@intCast(i), p(&arg_scratch), arg_scratch.len);
    return if (n < 0) "" else arg_scratch[0..@intCast(n)];
}
/// Whether the `i`-th binding opens a submenu (a group) vs a leaf command.
pub fn menuBindingIsGroup(i: usize) bool {
    return wl_menu_binding_is_group(@intCast(i)) != 0;
}
/// The accepted choice (valid during `on_pick_accept`), into `scratch`.
pub fn pickChoice() []const u8 {
    const n = wl_pick_choice(p(&scratch), scratch.len);
    return scratch[0..@intCast(n)];
}
/// The add-order index of the accepted candidate (the position in your
/// `pickAdd` sequence), or null for free text — resolve it against your own
/// parallel data to get the real target, robust under duplicate rows.
pub fn pickChoiceIndex() ?usize {
    const i = wl_pick_choice_index();
    return if (i < 0) null else @intCast(i);
}
/// The byte offset of the selected candidate's match against the accepted
/// query, or null for free-text acceptance. This is relative to the candidate
/// text supplied through `pickAdd`, not to the document that produced it.
pub fn pickChoiceMatchStart() ?usize {
    const i = wl_pick_choice_match_start();
    return if (i < 0) null else @intCast(i);
}

// ── Completion provider (the sel/completion domain) ──────────────────
// The host→guest data-gather membrane: the plugin registers a provider in
// `init` with `provideCompletion`, then the host calls the guest's exported
// `on_complete(session)` per request. The guest OWNS that session's answer: it
// offers items with `capsItem` and flushes them with `capsCommit`, or gives up
// with `capsDecline`. It may answer DURING on_complete (a sync source) or LATER
// off a poll (async — stash the `session`, commit when your data lands).

/// A rich completion candidate. `text` inserts/matches; `label` is the display
/// string (defaults to text when empty); `detail` is a right-aligned annotation
/// (a type/signature); `documentation` feeds the info popup; `kind` is the LSP
/// `CompletionItemKind` number (0 = unknown); `rank` orders within this source.
pub const Completion = struct {
    text: []const u8,
    label: []const u8 = &.{},
    detail: []const u8 = &.{},
    documentation: []const u8 = &.{},
    kind: u8 = 0,
    rank: i32 = 0,
};

/// Register this plugin as an `edit/completion` provider (declared as the
/// matching capability). Read-only — results race + merge-rank with everyone
/// else's.
pub fn provideCompletion() void {
    wl_provide_completion();
}
/// The current completion request's query prefix (valid for the duration of
/// `on_complete`). Its own scratch — safe to hold while calling `slice`. An
/// async source must copy it before deferring.
pub fn completionPrefix() []const u8 {
    const n = wl_completion_prefix(p(&prefix_scratch), prefix_scratch.len);
    return prefix_scratch[0..n];
}
/// Offer one candidate for `session` (accretes into a batch flushed by commit).
pub fn capsItem(session: u32, it: Completion) void {
    wl_caps_item(
        @bitCast(session),
        p(it.text.ptr),
        @intCast(it.text.len),
        p(it.label.ptr),
        @intCast(it.label.len),
        p(it.detail.ptr),
        @intCast(it.detail.len),
        @bitCast(@as(u32, it.kind)),
        p(it.documentation.ptr),
        @intCast(it.documentation.len),
        it.rank,
    );
}
/// Flush this source's offered items into `session` as one answer.
pub fn capsCommit(session: u32) void {
    wl_caps_commit(@bitCast(session));
}
/// Answer `session` with nothing (unsupported / no results / dead).
pub fn capsDecline(session: u32) void {
    wl_caps_decline(@bitCast(session));
}

// ── Activation (the buffer taking focus; valid during on_activate) ────
/// The path of the buffer that just took focus (into `scratch`). Empty for an
/// unbacked/scratch buffer. Call from an exported `on_activate` fn.
pub fn activatePath() []const u8 {
    const n = wl_activate_path(p(&scratch), scratch.len);
    return scratch[0..@intCast(n)];
}

// ── Structural read + subbuffers ─────────────────────────────────────
pub const Node = struct { kind: []const u8, start: usize, end: usize };

/// The smallest named tree-sitter node covering `offset` (kind + span), or
/// null when the buffer has no grammar / no node. Kind is in `scratch`.
pub fn nodeAt(offset: usize) ?Node {
    var span: [2]u32 = undefined;
    const n = wl_node_at(@intCast(offset), p(&scratch), scratch.len, p(&span));
    if (n < 0) return null;
    return .{ .kind = scratch[0..@intCast(n)], .start = span[0], .end = span[1] };
}

/// The smallest named tree-sitter node STRICTLY enclosing `[r.start, r.end)`
/// — repeat to grow a selection to the next scope. Kind is in `scratch`.
pub fn nodeEnclosing(r: Range) ?Node {
    var span: [2]u32 = undefined;
    const n = wl_node_enclosing(@intCast(r.start), @intCast(r.end), p(&scratch), scratch.len, p(&span));
    if (n < 0) return null;
    return .{ .kind = scratch[0..@intCast(n)], .start = span[0], .end = span[1] };
}

pub const Capture = struct { name: []const u8, start: usize, end: usize };
/// Run a tree-sitter query (`.scm`) over `[r.start, r.end)`; returns the
/// capture count, read back with `queryCapture(i)`. 0 if no grammar/error.
pub fn query(scm: []const u8, r: Range) usize {
    const n = wl_query(p(scm.ptr), @intCast(scm.len), @intCast(r.start), @intCast(r.end));
    return if (n < 0) 0 else @intCast(n);
}
/// The `i`-th capture of the last `query`/`nodeChildren` (name/kind into
/// `scratch`), or null.
pub fn queryCapture(i: usize) ?Capture {
    var span: [2]u32 = undefined;
    const n = wl_query_capture(@intCast(i), p(&scratch), scratch.len, p(&span));
    if (n < 0) return null;
    return .{ .name = scratch[0..@intCast(n)], .start = span[0], .end = span[1] };
}
/// The named children of the smallest node at `off` (structural descent);
/// returns the count, read back with `queryCapture(i)`. 0 if none/no grammar.
pub fn nodeChildren(off: usize) usize {
    const n = wl_node_children(@intCast(off));
    return if (n < 0) 0 else @intCast(n);
}

/// Claim `[start, end)` as a subbuffer (an anchored range with its own facts)
/// on the active document. Returns an opaque handle, or null if unavailable.
pub fn claimSubbuffer(start: usize, end: usize) ?u32 {
    const h = wl_claim_subbuffer(@intCast(start), @intCast(end));
    return if (h < 0) null else @intCast(h);
}
/// Attach a fact (`key` = `value`) to a claimed subbuffer.
pub fn subbufferPutFact(handle: u32, key: []const u8, value: []const u8) void {
    wl_subbuffer_put_fact(handle, p(key.ptr), @intCast(key.len), p(value.ptr), @intCast(value.len));
}
/// Release every subbuffer this plugin claimed — a projection clears before it
/// re-claims a fresh id-span per row each render, so stale spans never linger.
pub fn subbufferClear() void {
    wl_subbuffer_clear();
}
var subfact_scratch: [512]u8 = undefined;
/// Read fact `key` off the innermost subbuffer covering `offset` (in the shared
/// service — so it finds an id-span the register re-stamped on paste), or null.
/// The reconcile read-back: a row's hidden id → its original identity.
pub fn subbufferFactAt(offset: usize, key: []const u8) ?[]const u8 {
    const n = wl_subbuffer_fact_at(@intCast(offset), p(key.ptr), @intCast(key.len), p(&subfact_scratch), subfact_scratch.len);
    return if (n < 0) null else subfact_scratch[0..@intCast(n)];
}

/// Mark the active buffer as this plugin's tool projection (its content is
/// plugin-regenerated). A save then resolves the `save` action to a provider
/// this plugin registers for `When{ .tool = "<name>" }` — no core special-case.
pub fn toolBacking(name: []const u8) void {
    wl_tool_backing(p(name.ptr), @intCast(name.len));
}

// ── Register / kill (core, shared by every editor) ───────────────────
/// A private scratch for `registerText`, so a paste can hold the register bytes
/// while it reads the buffer through `slice`/`lineAt` (which reuse `scratch`).
var reg_scratch: [1 << 16]u8 = undefined;

/// Yank `[start, end)` into the shared register: captures the bytes, the
/// `linewise` flag, AND the facts of any subbuffer the range overlaps (a
/// projection row's hidden id), so a later `pasteAt` can ferry them. This is
/// the one door an editor's yank/delete calls — identity-ferrying is core, not
/// per-editor, so `dd`→`p` moves an id across editors and buffers alike.
pub fn yankRange(start: usize, end: usize, linewise: bool) void {
    yankRangeIn(0, start, end, linewise);
}
pub fn yankRangeIn(name: u8, start: usize, end: usize, linewise: bool) void {
    wl_yank_range(@intCast(start), @intCast(end), @intFromBool(linewise), name);
}
/// The register bytes (into a private scratch, valid until the next call) — for
/// an editor to build its paste. Charwise callers can insert these directly.
pub fn registerText() []const u8 {
    return registerTextIn(0);
}
pub fn registerTextIn(name: u8) []const u8 {
    const n = wl_register_text(p(&reg_scratch), reg_scratch.len, name);
    return reg_scratch[0..@intCast(n)];
}
/// Whether the register holds a linewise yank (the editor's paste-positioning
/// policy stays its own).
pub fn registerLinewise() bool {
    return registerLinewiseIn(0);
}
pub fn registerLinewiseIn(name: u8) bool {
    return wl_register_linewise(name) != 0;
}
/// Re-stamp any ferried id-spans over register text ALREADY inserted at `base`
/// (call right after inserting `registerText()`). Turns `dd`→`p` into a MOVE;
/// a plain insert with no call — or a register with no payloads — creates none.
pub fn pasteAt(base: usize) void {
    pasteAtIn(0, base);
}
pub fn pasteAtIn(name: u8, base: usize) void {
    wl_paste_at(@intCast(base), name);
}

// ── Generic semantic views ────────────────────────────────────────────
/// Whether the dispatching head currently focuses a live semantic view.
/// Editor plugins use this to translate their normal interaction model into
/// open actions; no tool identity or mode crosses this boundary.
pub fn semanticActive() bool {
    return wl_semantic_active() != 0;
}

/// Copy the dispatching head's validated working target. The returned value
/// owns its canonical decode and remains provider-neutral.
pub fn semanticWorkingTarget(gpa: std.mem.Allocator) (semantic_codec.Error || error{Rejected})!?semantic_codec.target.OwnedLocated {
    const result = wl_semantic_working_target(p(&scratch), scratch.len);
    if (result == 0) return null;
    if (result < 0) return error.Rejected;
    const len: usize = @intCast(result);
    if (len > scratch.len) return error.Rejected;
    return try semantic_codec.target.decodeLocated(gpa, scratch[0..len]);
}

/// Attach a retained semantic view to this head. NodeId is canonically split
/// into two wasm32 words; the explicit presence bit keeps an absent preference
/// distinct from any raw u64 value.
pub fn semanticViewFocus(ref: semantic.view.Ref, preferred: ?semantic.scene.NodeId) bool {
    const wire = ref.toWire();
    const raw: u64 = if (preferred) |node| @intFromEnum(node) else 0;
    const low: u32 = @truncate(raw);
    const high: u32 = @truncate(raw >> 32);
    return wl_semantic_view_focus(wire.authority, wire.slot, wire.generation, low, high, @intFromBool(preferred != null)) != 0;
}

/// Open a bounded head-local interaction definition using the canonical
/// scene codec. The host owns the decoded descriptor and returns a typed ref.
pub fn semanticInteractionOpen(definition: semantic.interaction.Definition) SemanticPublishError!semantic.interaction.Ref {
    const payload = try semantic_codec.encodeInteraction(allocator, definition);
    defer allocator.free(payload);
    var out: [12]u8 = undefined;
    if (wl_semantic_interaction_open(p(payload.ptr), @intCast(payload.len), p(&out), out.len) != 1) return error.Rejected;
    return readSemanticHandle(semantic.interaction.Ref, &out);
}

/// Close only the currently active interaction named by this typed ref.
pub fn semanticInteractionClose(ref: semantic.interaction.Ref) bool {
    const wire = ref.toWire();
    return wl_semantic_interaction_close(wire.authority, wire.slot, wire.generation) != 0;
}

pub const SemanticActionResult = enum(i32) {
    unavailable = 0,
    handled = 1,
    transfer_stored = 2,
    interaction_opened = 3,
    target_opened = 4,
    focus_changed = 5,
    relation_opened = 6,
    working_target_changed = 7,
    failed = -1,
    _,
};

pub fn semanticAction(action: []const u8) SemanticActionResult {
    return semanticActionIn(action, 0);
}
pub fn semanticActionIn(action: []const u8, slot: u8) SemanticActionResult {
    return @enumFromInt(wl_semantic_action(p(action.ptr), @intCast(action.len), slot));
}

/// Register this plugin as the single provider for scenes it owns. Core routes
/// by retained view ownership; the guest callback remains tool-defined.
pub fn semanticActionProvider() bool {
    return wl_semantic_action_provider() == 1;
}

pub const SemanticActionResponse = enum(u32) {
    declined = 0,
    handled = 1,
    transfer = 2,
    interaction = 3,
    open_target = 4,
    focus = 5,
    open_relation = 6,
    set_working_target = 7,
};

/// Read the request available only during `on_semantic_action()`.
pub fn semanticActionCurrent(gpa: std.mem.Allocator) (semantic_codec.Error || error{Rejected})!semantic_codec.action.OwnedRequest {
    const raw_len = wl_semantic_action_request_len();
    if (raw_len <= 0) return error.Rejected;
    const len: usize = @intCast(raw_len);
    const bytes = try gpa.alloc(u8, len);
    defer gpa.free(bytes);
    if (wl_semantic_action_request(p(bytes.ptr), @intCast(bytes.len)) != raw_len) return error.Rejected;
    return semantic_codec.action.decodeRequest(gpa, bytes);
}

fn semanticActionRespondEmpty(kind: SemanticActionResponse) bool {
    return wl_semantic_action_respond(@intFromEnum(kind), 0, 0) == 1;
}

pub fn semanticActionDecline() bool {
    return semanticActionRespondEmpty(.declined);
}

pub fn semanticActionHandled() bool {
    return semanticActionRespondEmpty(.handled);
}

pub fn semanticActionTransfer(item: semantic.transfer.Item) SemanticPublishError!void {
    const payload = try semantic_codec.transfer.encode(allocator, item);
    defer allocator.free(payload);
    if (wl_semantic_action_respond(@intFromEnum(SemanticActionResponse.transfer), p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

pub fn semanticActionInteraction(definition: semantic.interaction.Definition) SemanticPublishError!void {
    const payload = try semantic_codec.interaction.encode(allocator, definition);
    defer allocator.free(payload);
    if (wl_semantic_action_respond(@intFromEnum(SemanticActionResponse.interaction), p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

/// Ask core to resolve and admit one typed located target. Handler choice and
/// view ownership remain host policy; the guest supplies only this portable
/// request value.
pub fn semanticActionOpenTarget(located: semantic.target.Located) SemanticPublishError!void {
    const payload = try semantic_codec.encodeLocatedTarget(allocator, located);
    defer allocator.free(payload);
    if (wl_semantic_action_respond(@intFromEnum(SemanticActionResponse.open_target), p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

/// Ask core to move the dispatching head to another stable node in the same
/// retained view. The host validates membership before changing head state.
pub fn semanticActionFocus(node: semantic.scene.NodeId) bool {
    const raw: u64 = @intFromEnum(node);
    if (raw == 0) return false;
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, raw, .little);
    return wl_semantic_action_respond(@intFromEnum(SemanticActionResponse.focus), p(&bytes), bytes.len) == 1;
}

/// Ask core to resolve a named relation from an exact source target and open
/// the admitted destination. Handler choice remains host policy.
pub fn semanticActionOpenRelation(request: semantic.action.RelationRequest) SemanticPublishError!void {
    const payload = try semantic_codec.action.encodeRelation(allocator, request);
    defer allocator.free(payload);
    if (wl_semantic_action_respond(@intFromEnum(SemanticActionResponse.open_relation), p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

/// Ask core to make one exact whole target the dispatching head's working
/// container. No process cwd or provider path crosses this boundary.
pub fn semanticActionSetWorkingTarget(located: semantic.target.Located) SemanticPublishError!void {
    const payload = try semantic_codec.encodeLocatedTarget(allocator, located);
    defer allocator.free(payload);
    if (wl_semantic_action_respond(@intFromEnum(SemanticActionResponse.set_working_target), p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

pub const SemanticPublishError = semantic_codec.Error || error{Rejected};

pub const SemanticTargetDescribeError = semantic_codec.Error || error{Rejected};

fn readSemanticHandle(comptime Ref: type, bytes: *const [12]u8) SemanticPublishError!Ref {
    const wire: semantic.handle.Wire = .{
        .authority = std.mem.readInt(u32, bytes[0..4], .little),
        .slot = std.mem.readInt(u32, bytes[4..8], .little),
        .generation = std.mem.readInt(u32, bytes[8..12], .little),
    };
    if (wire.generation == 0) return error.Rejected;
    return Ref.fromWire(wire);
}

/// Publish a resource descriptor. Paths and schemes remain ordinary target
/// facts; target-handler plugins, not this SDK, decide what can open them.
pub fn semanticTargetPublish(definition: semantic.target.Definition) SemanticPublishError!semantic.target.Ref {
    const payload = try semantic_codec.encodeTarget(allocator, definition);
    defer allocator.free(payload);
    var out: [12]u8 = undefined;
    if (wl_semantic_target_publish(p(payload.ptr), @intCast(payload.len), p(&out), out.len) != 1) return error.Rejected;
    return readSemanticHandle(semantic.target.Ref, &out);
}

pub fn semanticTargetReplace(ref: semantic.target.Ref, definition: semantic.target.Definition) SemanticPublishError!void {
    const payload = try semantic_codec.encodeTarget(allocator, definition);
    defer allocator.free(payload);
    const wire = ref.toWire();
    if (wl_semantic_target_replace(wire.authority, wire.slot, wire.generation, p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

pub fn semanticTargetClose(ref: semantic.target.Ref) bool {
    const wire = ref.toWire();
    return wl_semantic_target_close(wire.authority, wire.slot, wire.generation) != 0;
}

/// Read a live target descriptor as one canonical, owned snapshot. The host
/// validates the authority/generation before encoding; the guest validates
/// that the returned descriptor still names the requested generation and has
/// a non-zero revision. A replacement racing the length/copy pair fails
/// closed rather than returning an ambiguous partial value.
pub fn semanticTargetDescribe(ref: semantic.target.Ref, gpa: std.mem.Allocator) SemanticTargetDescribeError!semantic_codec.target.OwnedDescriptor {
    const wire = ref.toWire();
    const raw_len = wl_semantic_target_describe_len(wire.authority, wire.slot, wire.generation);
    if (raw_len <= 0) return error.Rejected;
    const len: usize = @intCast(raw_len);
    if (len > semantic_codec.Limits.max_payload_bytes) return error.LimitExceeded;
    const bytes = try gpa.alloc(u8, len);
    defer gpa.free(bytes);
    const written = wl_semantic_target_describe(wire.authority, wire.slot, wire.generation, p(bytes.ptr), @intCast(bytes.len));
    if (written != raw_len) return error.Rejected;
    var descriptor = try semantic_codec.target.decodeDescriptor(gpa, bytes);
    errdefer descriptor.deinit();
    if (!descriptor.value.ref.eql(ref) or descriptor.value.revision == 0) return error.Rejected;
    return descriptor;
}

// ── Generic target-handler callbacks ─────────────────────────────────
// Handler registration deliberately has a guest-local phantom type. The
// target-runtime registry is a host implementation detail and is not imported
// into the guest module; only this stable three-word wire identity crosses the
// membrane.
pub const SemanticTargetHandlerTag = struct {};
pub const SemanticTargetHandlerRef = semantic.handle.Handle(SemanticTargetHandlerTag);
pub const TargetHandlerRef = SemanticTargetHandlerRef;

/// Errors a probe may report to the host. A probe that cannot handle a target
/// should normally use `semanticTargetHandlerProbeNone`; these errors are for
/// a provider that did recognize the target domain but cannot answer it.
pub const SemanticTargetProbeError = error{ Unavailable, InvalidTarget, Failed };

/// Errors an open may report after a successful probe. `StaleTarget` is
/// intentionally distinct from `Unavailable`: the host can refresh and retry
/// the former, while the latter is a provider-level absence.
pub const SemanticTargetOpenError = error{ StaleTarget, Unavailable, Rejected, Failed };

pub const SemanticTargetHandlerError = SemanticPublishError;

/// Register one stable handler token. `token` is returned to the callback
/// export, while `id` is metadata used by host diagnostics and resolution.
/// The returned reference is portable across heads and dired instances, but
/// only this plugin may close it.
pub fn semanticTargetHandlerRegister(token: u32, id: []const u8) SemanticTargetHandlerError!SemanticTargetHandlerRef {
    if (id.len == 0) return error.InvalidData;
    if (id.len > semantic_codec.Limits.max_string_bytes) return error.LimitExceeded;
    var out: [12]u8 = undefined;
    if (wl_semantic_target_handler_register(token, p(id.ptr), @intCast(id.len), p(&out), out.len) != 1)
        return error.Rejected;
    return readSemanticHandle(SemanticTargetHandlerRef, &out);
}

/// Remove a handler registration. The host invalidates the generation even if
/// a later plugin instance reuses the same slot.
pub fn semanticTargetHandlerClose(ref: SemanticTargetHandlerRef) bool {
    const wire = ref.toWire();
    return wl_semantic_target_handler_close(wire.authority, wire.slot, wire.generation) != 0;
}

/// Read and own the canonical request available only during
/// `on_semantic_target_probe` or `on_semantic_target_open`. The host supplies
/// one bounded payload; callers must use the returned codec-owned value's
/// `deinit` before returning from the callback.
fn semanticTargetHandlerRequest(gpa: std.mem.Allocator) (semantic_codec.Error || error{Rejected})![]u8 {
    const raw_len = wl_semantic_target_handler_request_len();
    if (raw_len <= 0) return error.Rejected;
    const len: usize = @intCast(raw_len);
    if (len > semantic_codec.Limits.max_payload_bytes) return error.LimitExceeded;
    const bytes = try gpa.alloc(u8, len);
    errdefer gpa.free(bytes);
    if (wl_semantic_target_handler_request(p(bytes.ptr), @intCast(bytes.len)) != raw_len)
        return error.Rejected;
    return bytes;
}

/// Decode the descriptor currently being probed. The returned descriptor owns
/// all strings/facts through its arena; call `deinit` after answering.
pub fn semanticTargetHandlerCurrentDescriptor(gpa: std.mem.Allocator) (semantic_codec.Error || error{Rejected})!semantic_codec.target.OwnedDescriptor {
    const bytes = try semanticTargetHandlerRequest(gpa);
    defer gpa.free(bytes);
    return semantic_codec.target.decodeDescriptor(gpa, bytes);
}

/// Decode the located target currently being opened. The returned value owns
/// all location payloads through its arena; call `deinit` after answering.
pub fn semanticTargetHandlerCurrentLocated(gpa: std.mem.Allocator) (semantic_codec.Error || error{Rejected})!semantic_codec.target.OwnedLocated {
    const bytes = try semanticTargetHandlerRequest(gpa);
    defer gpa.free(bytes);
    return semantic_codec.target.decodeLocated(gpa, bytes);
}

/// Resolve the probe response codes without exposing transport integers to a
/// plugin. The host accepts one response for each callback and rejects all
/// subsequent answers.
pub fn semanticTargetHandlerProbeNone() bool {
    return wl_semantic_target_handler_probe_respond(0) == 1;
}

pub fn semanticTargetHandlerProbeMatch(match: semantic.target.Match) bool {
    return wl_semantic_target_handler_probe_respond(1 + @as(u32, @intFromEnum(match))) == 1;
}

pub fn semanticTargetHandlerProbeError(err: SemanticTargetProbeError) bool {
    const code: u32 = switch (err) {
        error.Unavailable => 5,
        error.InvalidTarget => 6,
        error.Failed => 7,
    };
    return wl_semantic_target_handler_probe_respond(code) == 1;
}

/// Answer an open with a retained semantic view. The host validates the view
/// owner and target relationship before returning it to the resolver.
pub fn semanticTargetHandlerOpenView(view: semantic.view.Ref) bool {
    if (view.generation == 0) return false;
    const wire = view.toWire();
    return wl_semantic_target_handler_open_respond(0, wire.authority, wire.slot, wire.generation) == 1;
}

/// Answer an open with a newly provisioned view. The host settles this view
/// through `on_semantic_target_settle`; rejection means the plugin must undo
/// every resource created for the attempted open.
pub fn semanticTargetHandlerOpenProvisional(view: semantic.view.Ref) bool {
    if (view.generation == 0) return false;
    const wire = view.toWire();
    return wl_semantic_target_handler_open_respond(5, wire.authority, wire.slot, wire.generation) == 1;
}

pub fn semanticTargetHandlerOpenError(err: SemanticTargetOpenError) bool {
    const code: u32 = switch (err) {
        error.StaleTarget => 1,
        error.Unavailable => 2,
        error.Rejected => 3,
        error.Failed => 4,
    };
    return wl_semantic_target_handler_open_respond(code, 0, 0, 0) == 1;
}

// ── Generic relation-provider callbacks ───────────────────────────────
// Relation provider references are guest-local phantom handles. The host
// registry implementation and filesystem mechanisms never cross this API.
pub const SemanticRelationProviderTag = struct {};
pub const SemanticRelationProviderRef = semantic.handle.Handle(SemanticRelationProviderTag);
pub const RelationProviderRef = SemanticRelationProviderRef;

pub const SemanticRelationProviderError = SemanticPublishError;
pub const SemanticRelationQueryError = error{ Unavailable, InvalidRelation, StaleTarget, Failed };

pub fn semanticRelationProviderRegister(token: u32, id: []const u8) SemanticRelationProviderError!SemanticRelationProviderRef {
    if (id.len == 0) return error.InvalidData;
    if (id.len > semantic_codec.Limits.max_string_bytes) return error.LimitExceeded;
    var out: [12]u8 = undefined;
    if (wl_semantic_relation_provider_register(token, p(id.ptr), @intCast(id.len), p(&out), out.len) != 1)
        return error.Rejected;
    return readSemanticHandle(SemanticRelationProviderRef, &out);
}

pub fn semanticRelationProviderClose(ref: SemanticRelationProviderRef) bool {
    const wire = ref.toWire();
    return wl_semantic_relation_provider_close(wire.authority, wire.slot, wire.generation) != 0;
}

/// Read the query available only during `on_semantic_relation_query(token)`.
pub fn semanticRelationCurrentQuery(gpa: std.mem.Allocator) (semantic_codec.Error || error{Rejected})!semantic_codec.action.OwnedRelation {
    const raw_len = wl_semantic_relation_request_len();
    if (raw_len <= 0) return error.Rejected;
    const len: usize = @intCast(raw_len);
    if (len > semantic_codec.Limits.max_payload_bytes) return error.LimitExceeded;
    const bytes = try gpa.alloc(u8, len);
    defer gpa.free(bytes);
    if (wl_semantic_relation_request(p(bytes.ptr), @intCast(bytes.len)) != raw_len) return error.Rejected;
    return semantic_codec.action.decodeRelation(gpa, bytes);
}

pub fn semanticRelationRespondNone() bool {
    return wl_semantic_relation_respond(0, 0, 0) == 1;
}

/// Return only the located destination. The host supplies the exact relation
/// name from the query and validates target liveness before callers can open
/// it, so a guest cannot rename an edge in its response.
pub fn semanticRelationRespondTarget(target: semantic.target.Located) SemanticRelationProviderError!void {
    const payload = try semantic_codec.target.encodeLocated(allocator, target);
    defer allocator.free(payload);
    if (wl_semantic_relation_respond(1, p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

pub fn semanticRelationRespondError(err: SemanticRelationQueryError) bool {
    const kind: u32 = switch (err) {
        error.Unavailable => 2,
        error.InvalidRelation => 3,
        error.StaleTarget => 4,
        error.Failed => 5,
    };
    return wl_semantic_relation_respond(kind, 0, 0) == 1;
}

/// Publish a retained scene. A null target is represented canonically by an
/// all-zero wire tuple and cannot be confused with a live generation.
pub fn semanticViewPublish(root: semantic.scene.Node, target: ?semantic.target.Ref, revision: u32) SemanticPublishError!semantic.view.Ref {
    const payload = try semantic_codec.encodeScene(allocator, root);
    defer allocator.free(payload);
    const target_wire: semantic.handle.Wire = if (target) |ref| ref.toWire() else .{ .authority = 0, .slot = 0, .generation = 0 };
    var out: [12]u8 = undefined;
    if (wl_semantic_view_publish(
        p(payload.ptr),
        @intCast(payload.len),
        target_wire.authority,
        target_wire.slot,
        target_wire.generation,
        revision,
        p(&out),
        out.len,
    ) != 1) return error.Rejected;
    return readSemanticHandle(semantic.view.Ref, &out);
}

pub fn semanticViewReplace(ref: semantic.view.Ref, revision: u32, root: semantic.scene.Node) SemanticPublishError!void {
    const payload = try semantic_codec.encodeScene(allocator, root);
    defer allocator.free(payload);
    const wire = ref.toWire();
    if (wl_semantic_view_replace(wire.authority, wire.slot, wire.generation, revision, p(payload.ptr), @intCast(payload.len)) != 1)
        return error.Rejected;
}

pub fn semanticViewClose(ref: semantic.view.Ref) bool {
    const wire = ref.toWire();
    return wl_semantic_view_close(wire.authority, wire.slot, wire.generation) != 0;
}

pub const SemanticFieldSnapshot = struct {
    revision: []const u8,
    bytes: []const u8,
    selection: SemanticFieldSelection,
    read_only: bool = false,
    single_line: bool = false,
};

pub const SemanticFieldSelection = struct {
    anchor: u32,
    caret: u32,
};

fn semanticFieldFlags(snapshot: SemanticFieldSnapshot) u32 {
    return @as(u32, @intFromBool(snapshot.read_only)) |
        (@as(u32, @intFromBool(snapshot.single_line)) << 1);
}

pub fn semanticFieldRegister(token: u32, snapshot: SemanticFieldSnapshot) SemanticPublishError!semantic.scene.FieldRef {
    var out: [12]u8 = undefined;
    if (wl_semantic_field_register(
        token,
        p(snapshot.revision.ptr),
        @intCast(snapshot.revision.len),
        p(snapshot.bytes.ptr),
        @intCast(snapshot.bytes.len),
        snapshot.selection.anchor,
        snapshot.selection.caret,
        semanticFieldFlags(snapshot),
        p(&out),
        out.len,
    ) != 1) return error.Rejected;
    return readSemanticHandle(semantic.scene.FieldRef, &out);
}

pub fn semanticFieldUpdate(ref: semantic.scene.FieldRef, snapshot: SemanticFieldSnapshot) SemanticPublishError!void {
    const wire = ref.toWire();
    if (wl_semantic_field_update(
        wire.authority,
        wire.slot,
        wire.generation,
        p(snapshot.revision.ptr),
        @intCast(snapshot.revision.len),
        p(snapshot.bytes.ptr),
        @intCast(snapshot.bytes.len),
        snapshot.selection.anchor,
        snapshot.selection.caret,
        semanticFieldFlags(snapshot),
    ) != 1) return error.Rejected;
}

pub fn semanticFieldClose(ref: semantic.scene.FieldRef) bool {
    const wire = ref.toWire();
    return wl_semantic_field_close(wire.authority, wire.slot, wire.generation) != 0;
}

pub const SemanticFieldEdit = struct {
    storage_allocator: std.mem.Allocator,
    expected_revision: []u8,
    start: u32,
    end: u32,
    replacement: []u8,
    selection_after: ?SemanticFieldSelection,

    pub fn deinit(self: *SemanticFieldEdit) void {
        self.storage_allocator.free(self.replacement);
        self.storage_allocator.free(self.expected_revision);
        self.* = undefined;
    }
};

/// Read the request available only during `on_semantic_field_edit(token)`.
/// The returned bytes are owned by `gpa`; call `deinit` after updating or
/// rejecting the field in provider code.
pub fn semanticFieldCurrentEdit(gpa: std.mem.Allocator) (std.mem.Allocator.Error || error{Rejected})!SemanticFieldEdit {
    var meta: [28]u8 = undefined;
    if (wl_semantic_field_edit_meta(p(&meta), meta.len) != meta.len) return error.Rejected;
    const start = std.mem.readInt(u32, meta[0..4], .little);
    const end = std.mem.readInt(u32, meta[4..8], .little);
    const revision_len = std.mem.readInt(u32, meta[8..12], .little);
    const replacement_len = std.mem.readInt(u32, meta[12..16], .little);
    const has_selection = std.mem.readInt(u32, meta[16..20], .little);
    if (has_selection > 1) return error.Rejected;
    const revision = try gpa.alloc(u8, revision_len);
    errdefer gpa.free(revision);
    const replacement = try gpa.alloc(u8, replacement_len);
    errdefer gpa.free(replacement);
    if (wl_semantic_field_edit_revision(p(revision.ptr), revision_len) != revision_len or
        (replacement_len != 0 and wl_semantic_field_edit_replacement(p(replacement.ptr), replacement_len) != replacement_len))
        return error.Rejected;
    return .{
        .storage_allocator = gpa,
        .expected_revision = revision,
        .start = start,
        .end = end,
        .replacement = replacement,
        .selection_after = if (has_selection == 1) .{
            .anchor = std.mem.readInt(u32, meta[20..24], .little),
            .caret = std.mem.readInt(u32, meta[24..28], .little),
        } else null,
    };
}

// ── Effects (perm-gated) ─────────────────────────────────────────────
/// Run `cmd` in a shell off the frame thread; insert its stdout at the cursor
/// when it finishes, rebased. Perms: proc + timer (declared in `describe`).
pub fn shellInsert(cmd: []const u8) void {
    wl_shell_insert(p(cmd.ptr), @intCast(cmd.len));
}

// ── Interactive REPL sessions (persistent child + comint buffer) ──────
/// Start a persistent REPL running `cmd` under a shell, streaming its output
/// into buffer `name`. Returns a session handle, or null. Perms: proc + timer.
pub fn replStart(cmd: []const u8, name: []const u8) ?u32 {
    const h = wl_repl_start(p(cmd.ptr), @intCast(cmd.len), p(name.ptr), @intCast(name.len));
    return if (h < 0) null else @intCast(h);
}
/// Write a line to a REPL session's stdin (a newline is appended if absent).
pub fn replSend(handle: u32, line: []const u8) void {
    wl_repl_send(handle, p(line.ptr), @intCast(line.len));
}
/// Terminate a REPL session.
pub fn replQuit(handle: u32) void {
    wl_repl_quit(handle);
}

/// Spawn a persistent subprocess whose stdout comes BACK to the guest (via
/// `procRead`), for an in-guest protocol client. Returns a handle, or null.
pub fn procSpawn(cmd: []const u8) ?u32 {
    const h = wl_proc_spawn(p(cmd.ptr), @intCast(cmd.len));
    return if (h < 0) null else @intCast(h);
}
/// Write bytes to the subprocess's stdin.
pub fn procSend(handle: u32, bytes: []const u8) void {
    wl_proc_send(handle, p(bytes.ptr), @intCast(bytes.len));
}
/// Drain up to `out.len` buffered stdout bytes; returns the slice read (may be
/// empty). Valid until the next call.
pub fn procRead(handle: u32, out: []u8) []u8 {
    const n = wl_proc_read(handle, p(out.ptr), @intCast(out.len));
    return if (n <= 0) out[0..0] else out[0..@intCast(n)];
}
/// Kill the subprocess (its handle stays reserved).
pub fn procClose(handle: u32) void {
    wl_proc_close(handle);
}
/// The process working directory (for absolute `file://` uris). Uses the shared
/// scratch — copy it before the next read call.
pub fn cwd() []const u8 {
    const n = wl_cwd(p(&scratch), scratch.len);
    return if (n <= 0) "" else scratch[0..@intCast(n)];
}

// ── net.connect (TCP / TLS) — perm net ───────────────────────────────
/// Dial `hostport`, streaming the socket into buffer `name`. If `sni` is
/// non-empty, run TLS verifying that host name. Returns a handle, or null.
pub fn netConnect(hostport: []const u8, name: []const u8, sni: []const u8) ?u32 {
    const h = wl_net_connect(p(hostport.ptr), @intCast(hostport.len), p(name.ptr), @intCast(name.len), p(sni.ptr), @intCast(sni.len));
    return if (h < 0) null else @intCast(h);
}
/// Send bytes on a connection.
pub fn netSend(handle: u32, bytes: []const u8) void {
    wl_net_send(handle, p(bytes.ptr), @intCast(bytes.len));
}
/// Close a connection.
pub fn netClose(handle: u32) void {
    wl_net_close(handle);
}

/// Run `cmd` off the frame thread and replace the scratch buffer named `name`
/// (found or created) with its stdout — tool output → a buffer (git status,
/// grep, compile). Perms: proc + timer (declared in `describe`).
pub fn procToBuffer(cmd: []const u8, name: []const u8) void {
    wl_proc_to_buffer(p(cmd.ptr), @intCast(cmd.len), p(name.ptr), @intCast(name.len));
}
/// Like `procToBuffer` but APPENDS the output — a console/comint log.
pub fn procAppendBuffer(cmd: []const u8, name: []const u8) void {
    wl_proc_append_buffer(p(cmd.ptr), @intCast(cmd.len), p(name.ptr), @intCast(name.len));
}

/// Filter `[r.start, r.end)` through `cmd` (a `{}` placeholder gets a temp file
/// the range is written to, transformed in place, and read back) and replace
/// the range with the result — formatters and vim `!`-filters. Async, rebased,
/// authored as this plugin's peer. Perms: proc + timer.
pub fn procFilter(cmd: []const u8, r: Range) void {
    wl_proc_filter(p(cmd.ptr), @intCast(cmd.len), @intCast(r.start), @intCast(r.end));
}

// ── fs (perm-gated fs_read / fs_write) — local, cwd-relative ──────────
// A missing perm never reaches these as -1/null: the host traps the call
// outright (doc/north-star-plan.md §2.4 review C9), so a plugin that hasn't
// requested the perm never even gets back here. The degrade values below are
// for legitimate misses (not found / too big / not a directory) only.
/// Read a file into `scratch` (valid until the next read call), or null (not
/// found / too big). Perm: fs_read.
pub fn fsRead(fpath: []const u8) ?[]const u8 {
    const n = wl_fs_read(p(fpath.ptr), @intCast(fpath.len), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}
/// What `fpath` is, without reading it. Perm: fs_read. Cheap enough to climb a
/// directory chain probing for a marker (e.g. `.git`) — project-root detection.
pub const FsKind = enum(i32) { none = 0, file = 1, dir = 2, other = 3 };
pub fn fsExists(fpath: []const u8) FsKind {
    const k = wl_fs_exists(p(fpath.ptr), @intCast(fpath.len));
    return switch (k) {
        1 => .file,
        2 => .dir,
        3 => .other,
        else => .none, // 0 absent
    };
}
/// Replace a file with `bytes`. Perm: fs_write. Returns success.
pub fn fsWrite(fpath: []const u8, bytes: []const u8) bool {
    return wl_fs_write(p(fpath.ptr), @intCast(fpath.len), p(bytes.ptr), @intCast(bytes.len)) == 0;
}
/// Append `bytes` to a file (created if absent). Perm: fs_write. Returns success.
pub fn fsAppend(fpath: []const u8, bytes: []const u8) bool {
    return wl_fs_append(p(fpath.ptr), @intCast(fpath.len), p(bytes.ptr), @intCast(bytes.len)) == 0;
}
/// List a directory at `authority` (locus): "here" for the local fs; a peer/
/// shell authority once the collab transport is wired. Entries newline-joined,
/// directories with a trailing `/`, into `scratch` (valid until the next read).
/// null = unresolved authority / not a directory. Perm: fs_read.
pub fn fsList(authority: []const u8, dir: []const u8) ?[]const u8 {
    const n = wl_fs_list(p(authority.ptr), @intCast(authority.len), p(dir.ptr), @intCast(dir.len), p(&scratch), scratch.len);
    if (n < 0) return null;
    return scratch[0..@intCast(n)];
}
/// Asynchronously list a REMOTE directory ("peer"): the listing is delivered
/// into the `dest` buffer a few frames later (no blocking round-trip). Returns
/// true if queued (a connected session exists), false otherwise. For local
/// listings use the synchronous `fsList("here", …)`.
pub fn fsListAsync(authority: []const u8, dir: []const u8, dest: []const u8) bool {
    return wl_fs_list_async(p(authority.ptr), @intCast(authority.len), p(dir.ptr), @intCast(dir.len), p(dest.ptr), @intCast(dest.len)) == 0;
}

/// Typed status returned by the target-scoped filesystem membrane.  A
/// non-negative host result is an encoded response length; these values are
/// only used internally by the retrying wrappers below.
pub const SemanticFsError = fs_codec.Error || semantic_codec.Error || error{
    Unavailable,
    StaleTarget,
    Unsupported,
    InvalidTarget,
    Failed,
};

fn semanticFsError(code: i32) SemanticFsError!void {
    switch (code) {
        -1 => return error.Unavailable,
        -2 => return error.StaleTarget,
        -3 => return error.Unsupported,
        -4 => return error.InvalidTarget,
        -5 => return error.Failed,
        else => if (code < 0) return error.Failed,
    }
}

fn semanticFsRevisionLow(revision: u64) u32 {
    return @intCast(revision & 0xffff_ffff);
}

fn semanticFsRevisionHigh(revision: u64) u32 {
    return @intCast(revision >> 32);
}

/// Publish an observed direct child directory as a new independently confined
/// semantic target. The request carries only the live parent target and
/// guarded entry identity; the host re-reads the provider name and derives a
/// new root, so neither a raw root capability nor a filename is trusted from
/// guest memory.
pub fn semanticFsPublishChildDirectory(
    gpa: std.mem.Allocator,
    parent: semantic.target.Located,
    entry: fs.contract.EntryRef,
    revision: fs.contract.Revision,
) SemanticFsError!semantic.target.Located {
    return semanticFsPublishChild(.directory, gpa, parent, entry, revision);
}

/// Publish an observed direct child regular file as an ordinary semantic
/// target. The guest supplies the same guarded provider identity used for a
/// directory child; it never supplies a path, root capability, or target
/// facts. Which plugin, if any, handles the resulting target is independent.
pub fn semanticFsPublishChildFile(
    gpa: std.mem.Allocator,
    parent: semantic.target.Located,
    entry: fs.contract.EntryRef,
    revision: fs.contract.Revision,
) SemanticFsError!semantic.target.Located {
    return semanticFsPublishChild(.file, gpa, parent, entry, revision);
}

const SemanticFsChildKind = enum { directory, file };

fn semanticFsPublishChild(
    comptime kind: SemanticFsChildKind,
    gpa: std.mem.Allocator,
    parent: semantic.target.Located,
    entry: fs.contract.EntryRef,
    revision: fs.contract.Revision,
) SemanticFsError!semantic.target.Located {
    const request = try fs_codec.child_directory.encode(gpa, .{
        .parent = parent,
        .entry = entry,
        .revision = revision,
    });
    defer gpa.free(request);
    var output: [64]u8 = undefined;
    const result = switch (kind) {
        .directory => wl_semantic_fs_publish_child_directory(p(request.ptr), @intCast(request.len), p(&output), output.len),
        .file => wl_semantic_fs_publish_child_file(p(request.ptr), @intCast(request.len), p(&output), output.len),
    };
    try semanticFsError(result);
    const result_len: usize = @intCast(result);
    if (result_len > output.len) return error.Failed;
    var located = try semantic_codec.target.decodeLocated(gpa, output[0..result_len]);
    defer located.deinit();
    switch (located.value.location) {
        .whole => {},
        else => return error.InvalidTarget,
    }
    return located.value;
}

/// Query provider policy for the exact target revision.  The result is
/// descriptive only: the host re-authorizes every filesystem operation, so a
/// capability bit can never be used as an ambient root or operation grant.
pub fn semanticFsCapabilities(
    gpa: std.mem.Allocator,
    target: semantic.target.Ref,
    revision: u64,
) SemanticFsError!fs.contract.Capabilities {
    const wire = target.toWire();
    var capacity: usize = 64;
    while (true) {
        if (capacity > fs_codec.Limits.max_payload_bytes) capacity = fs_codec.Limits.max_payload_bytes;
        const bytes = try gpa.alloc(u8, capacity);
        defer gpa.free(bytes);
        const result = wl_semantic_fs_capabilities(
            wire.authority,
            wire.slot,
            wire.generation,
            semanticFsRevisionLow(revision),
            semanticFsRevisionHigh(revision),
            p(bytes.ptr),
            @intCast(bytes.len),
        );
        if (result == -6) {
            if (capacity == fs_codec.Limits.max_payload_bytes) return error.LimitExceeded;
            capacity = @min(capacity * 2, fs_codec.Limits.max_payload_bytes);
            continue;
        }
        try semanticFsError(result);
        const result_len: usize = @intCast(result);
        if (result_len > bytes.len) return error.Failed;
        return fs_codec.decodeCapabilities(gpa, bytes[0..result_len]);
    }
}

/// List the exact directory attachment of a live target revision.  The
/// response buffer grows only up to the codec's canonical payload limit, so
/// callers do not need to expose a fixed-size dired scratch area.
pub fn semanticFsList(gpa: std.mem.Allocator, target: semantic.target.Ref, revision: u64) SemanticFsError!fs_codec.OwnedListing {
    const wire = target.toWire();
    var capacity: usize = 4096;
    while (true) {
        if (capacity > fs_codec.Limits.max_payload_bytes) capacity = fs_codec.Limits.max_payload_bytes;
        const bytes = try gpa.alloc(u8, capacity);
        defer gpa.free(bytes);
        const result = wl_semantic_fs_list(wire.authority, wire.slot, wire.generation, semanticFsRevisionLow(revision), semanticFsRevisionHigh(revision), p(bytes.ptr), @intCast(bytes.len));
        if (result == -6) {
            if (capacity == fs_codec.Limits.max_payload_bytes) return error.LimitExceeded;
            capacity = @min(capacity * 2, fs_codec.Limits.max_payload_bytes);
            continue;
        }
        try semanticFsError(result);
        const result_len: usize = @intCast(result);
        if (result_len > bytes.len) return error.Failed;
        return fs_codec.decodeListing(gpa, bytes[0..result_len]);
    }
}

/// Apply a canonical typed plan against the exact target revision.  Cross-root
/// sources are rejected by the host until a provider supplies an explicit
/// durable lease; this wrapper therefore carries no ambient root capability.
pub fn semanticFsApply(gpa: std.mem.Allocator, target: semantic.target.Ref, revision: u64, effect_plan: fs.contract.Plan) SemanticFsError!fs_codec.OwnedApplyReport {
    const plan_bytes = try fs_codec.encodePlan(gpa, effect_plan);
    defer gpa.free(plan_bytes);
    const wire = target.toWire();
    var capacity: usize = 4096;
    while (true) {
        if (capacity > fs_codec.Limits.max_payload_bytes) capacity = fs_codec.Limits.max_payload_bytes;
        const bytes = try gpa.alloc(u8, capacity);
        defer gpa.free(bytes);
        const result = wl_semantic_fs_apply(wire.authority, wire.slot, wire.generation, semanticFsRevisionLow(revision), semanticFsRevisionHigh(revision), p(plan_bytes.ptr), @intCast(plan_bytes.len), p(bytes.ptr), @intCast(bytes.len));
        if (result == -6) {
            if (capacity == fs_codec.Limits.max_payload_bytes) return error.LimitExceeded;
            capacity = @min(capacity * 2, fs_codec.Limits.max_payload_bytes);
            continue;
        }
        try semanticFsError(result);
        const result_len: usize = @intCast(result);
        if (result_len > bytes.len) return error.Failed;
        return fs_codec.decodeApplyReport(gpa, bytes[0..result_len]);
    }
}

pub const SemanticTransferError = SemanticFsError || error{InvalidAttachment};

fn semanticTransferError(code: i32) SemanticTransferError!void {
    switch (code) {
        -1 => return error.Unavailable,
        -2 => return error.StaleTarget,
        -3 => return error.Unsupported,
        -4 => return error.InvalidAttachment,
        -5 => return error.Failed,
        -6 => return error.LimitExceeded,
        else => if (code < 0) return error.Failed,
    }
}

/// Materialize an authorized filesystem entry for use by a semantic
/// transfer. The result carries an owner-scoped wire identifier and the
/// provider lease source it may name in a plan; neither is an ambient
/// filesystem capability without host-side registry authorization.
pub const SemanticTransferCapture = struct {
    attachment: semantic.transfer.Attachment,
    source: fs.contract.LeaseSource,
};

pub fn semanticTransferCapture(
    target: semantic.target.Ref,
    target_revision: u64,
    source: fs.contract.EntrySource,
) SemanticTransferError!SemanticTransferCapture {
    const target_wire = target.toWire();
    var out: [36]u8 = undefined;
    const result = wl_semantic_transfer_capture(
        target_wire.authority,
        target_wire.slot,
        target_wire.generation,
        semanticFsRevisionLow(target_revision),
        semanticFsRevisionHigh(target_revision),
        @intFromEnum(source.root.authority),
        source.root.slot,
        source.root.generation,
        @intFromEnum(source.ref.authority),
        source.ref.slot,
        source.ref.generation,
        p(source.revision.token.ptr),
        @intCast(source.revision.token.len),
        p(&out),
        out.len,
    );
    try semanticTransferError(result);
    if (result != out.len) return error.Failed;
    return .{
        .attachment = semantic.transfer.Attachment.fromWire(.{
            .authority = std.mem.readInt(u32, out[0..4], .little),
            .slot = std.mem.readInt(u32, out[4..8], .little),
            .generation = std.mem.readInt(u32, out[8..12], .little),
        }),
        .source = .{
            .root = .{
                .authority = @enumFromInt(std.mem.readInt(u32, out[12..16], .little)),
                .slot = std.mem.readInt(u32, out[16..20], .little),
                .generation = std.mem.readInt(u32, out[20..24], .little),
            },
            .ref = .{
                .authority = @enumFromInt(std.mem.readInt(u32, out[24..28], .little)),
                .slot = std.mem.readInt(u32, out[28..32], .little),
                .generation = std.mem.readInt(u32, out[32..36], .little),
            },
        },
    };
}

pub fn semanticTransferRetain(attachment: semantic.transfer.Attachment) bool {
    const wire = attachment.toWire();
    return wl_semantic_transfer_retain(wire.authority, wire.slot, wire.generation) == 1;
}

pub fn semanticTransferRelease(attachment: semantic.transfer.Attachment) bool {
    const wire = attachment.toWire();
    return wl_semantic_transfer_release(wire.authority, wire.slot, wire.generation) == 1;
}

// ── D2: generic, schema-directed slots (doc/d2-schema-payloads.md §6) ────
// A third-party plugin declares a NOVEL slot with a NOVEL result shape —
// core has no type for it, ever. `slotDeclare` ships the schema TREE as its
// canonical blob (`schema.canonicalizeSchema` — the same module the host
// runs, `weft_schema` above); `slotBind` registers a provider; `payloadPush`
// answers a fired session with schema-encoded bytes the host restamps and a
// consumer decodes with `schema.decodeCursor` — none of which core
// recompiles for.

pub const SlotShape = enum(u32) { query = 0, feed = 1, action = 2, value = 3 };
pub const SlotComposition = enum(u32) { first_wins = 0, ordered_union = 1, merge_ranked = 2 };
pub const SlotTier = enum(u32) { core = 0, imported = 1, plugin = 2, config = 3, transient = 4 };

/// Runtime-declare a slot (`wl_slot_declare`) — no core recompile, no core
/// type: `sch` crosses as its own canonical blob.
pub fn slotDeclare(name: []const u8, shape: SlotShape, composition: SlotComposition, sch: *const schema.Schema) void {
    const blob = schema.canonicalizeSchema(allocator, sch) catch return;
    defer allocator.free(blob);
    wl_slot_declare(p(name.ptr), @intCast(name.len), @intFromEnum(shape), @intFromEnum(composition), p(blob.ptr), @intCast(blob.len));
}

/// A single-axis predicate for `slotBind` — the wire micro-format
/// `wasm_host/slot.zig`'s `parsePredicate` decodes (see that file's module
/// doc for why this is deliberately not a full self-hosted `facts.Predicate`
/// yet — a disclosed, bounded simplification, not the end state).
pub const SlotPredicate = union(enum) { all, mode: []const u8, ext: []const u8, lang: []const u8, tool: []const u8 };

fn putUvLocal(buf: []u8, v: u64) usize {
    var x = v;
    var i: usize = 0;
    while (true) {
        const b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x == 0) {
            buf[i] = b;
            return i + 1;
        }
        buf[i] = b | 0x80;
        i += 1;
    }
}

/// Bind a provider for an already-declared slot (`wl_slot_bind`).
pub fn slotBind(name: []const u8, pred: SlotPredicate, tier: SlotTier, priority: i32) void {
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    const leaf: ?struct { tag: u8, s: []const u8 } = switch (pred) {
        .all => null,
        .mode => |s| .{ .tag = 1, .s = s },
        .ext => |s| .{ .tag = 2, .s = s },
        .lang => |s| .{ .tag = 3, .s = s },
        .tool => |s| .{ .tag = 4, .s = s },
    };
    if (leaf) |lf| {
        buf[0] = lf.tag;
        len = 1;
        len += putUvLocal(buf[len..], lf.s.len);
        @memcpy(buf[len..][0..lf.s.len], lf.s);
        len += lf.s.len;
    }
    wl_slot_bind(p(name.ptr), @intCast(name.len), p(&buf), @intCast(len), @intFromEnum(tier), priority);
}

/// Push one schema-encoded payload for a fired `session` (`wl_payload_push`).
/// `version` is this plugin's `SchemaRef` for the slot (§2.3) — the host
/// never trusts a `range`-marked field's claimed version either way (it
/// restamps those unconditionally); this is metadata for future skew
/// detection, not currently checked (see `wasm_host/slot.zig`'s doc).
pub fn payloadPush(session: u32, version: u32, sch: *const schema.Schema, value: schema.Value) void {
    const bytes = schema.encode(allocator, sch, value) catch return;
    defer allocator.free(bytes);
    wl_payload_push(@bitCast(session), version, p(bytes.ptr), @intCast(bytes.len));
}

var slot_scratch: [1 << 16]u8 = undefined;

/// The fired session's schema-encoded REQUEST payload (`wl_payload_read`),
/// into a private scratch — empty if there is none. Valid until the next call.
pub fn payloadRead(session: u32) []const u8 {
    const n = wl_payload_read(@bitCast(session), p(&slot_scratch), slot_scratch.len);
    if (n < 0) return &.{};
    return slot_scratch[0..@intCast(n)];
}
