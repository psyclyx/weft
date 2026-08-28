//! core/membrane/contract_data.zig — the PURE DATA half of the `weft.*`
//! guest↔host import membrane: name, param/result shape (with guest-source
//! signedness), permission gate, and doc, for every `wl_*` import, plus the
//! host→guest EXPORT entrypoints (describe/init/run/on_command/…). No
//! wasmtime, no handler function pointers — this file has zero host-only
//! dependencies, so it compiles under `wasm32-freestanding` and is imported
//! directly by src/guest/weft.zig (the guest-side comptime tripwire) as well
//! as by core/membrane/contract.zig (the host-side handler binding).
//!
//! Split from contract.zig (doc/extensibility-native-surface.md, task W0a-D): the
//! ORIGINAL table interleaved this data with `HostFn` handler pointers,
//! which drags in wasmtime (`wasm.zig`) and the whole `wasm_host/*` tree —
//! neither of which links for a wasm32 guest. contract.zig now zips this
//! table's data against a host-only `handlers` list by NAME (not position),
//! comptime-checked both ways: every data entry must have a bound handler,
//! and every handler must name a real data entry. See that file for the
//! zip; see src/guest/weft.zig for the guest-side verification this data
//! enables.
//!
//! Zig 0.16 cannot reify a `extern fn` declaration OR a struct-of-decls from
//! a runtime-driven comptime loop (no `@Type` builtin, no `usingnamespace`
//! decl-merging) — so this table does not literally GENERATE the guest
//! externs in src/guest/weft.zig; those stay hand-written. What it generates
//! instead is a comptime VERIFICATION: weft.zig walks `imports` and, for
//! each entry, uses `@field(@This(), entry.name)` + `@typeInfo` to confirm
//! the hand-written extern's arity AND per-param/result signedness match
//! this table exactly — a drift (wrong type, wrong count, or a missing
//! extern entirely) fails the BUILD, not silently. That is what "the
//! comptime tripwire... replaces the AND-mirror-by-hand comment" (task
//! W0a-D) means in practice: you still write the extern line by hand, but
//! forgetting or misspelling it no longer compiles.

const std = @import("std");

/// The wasm-level value crossing the membrane, carrying GUEST-SOURCE
/// signedness. Every `wl_*` import is a scalar i32/u32 (or a `(ptr,len)`
/// pair of them for bulk data) at the wasm level — both `i32` and `u32`
/// lower to the same wasm valtype `i32`; wasmtime's `Linker`/`Caller` only
/// ever see word count, never sign. This enum exists for the GUEST side:
/// src/guest/weft.zig's hand-written externs mix `u32` (the common case)
/// and `i32` (sentinel -1 results, a handful of signed args) — this table
/// records exactly which, transcribed from those externs, so the
/// verification block in weft.zig can catch a signedness slip too, not
/// just an arity slip.
pub const ValType = enum { i32, u32 };

/// Which `wasm_host/*.zig` module owns an entry's handler. Also the table's
/// sort key: entries below are grouped contiguously (not call-historical
/// order) so a reviewer can see one module's whole surface at a glance.
pub const Group = enum {
    declare,
    edit,
    layers,
    /// `wasm_host/annotate.zig` — the third-party decoration package
    /// (doc/contextual-workspace-architecture.md §11.7): named annotation
    /// feeds published onto a REFERENCED entry, stamped with the revision
    /// they were computed against. Its own group, not folded into `.layers`:
    /// that group is the ACTIVE-buffer builtin-feed surface (styles/folds/
    /// decorations), which the standing rules deliberately keep a decorator
    /// out of.
    annotate,
    config_kv,
    dispatch,
    keymap,
    commands,
    /// `wasm_host/intent.zig` — the focused context's live offers, enumerated
    /// for a UI, plus the resolve-then-invoke door one is accepted through.
    intent,
    buffers,
    pick,
    menu,
    surface,
    capability,
    syntax,
    activation,
    tool,
    register,
    semantic,
    proc,
    sessions,
    fs,
    /// D2's generic, schema-directed slot verbs (doc/d2-schema-payloads.md
    /// §3.2) — `wl_slot_declare`/`wl_slot_bind`/`wl_payload_push`/
    /// `wl_payload_read`, handled by `wasm_host/slot.zig`. Deliberately its
    /// own group, not folded into `.capability`: that group is the
    /// COMPLETION-specific `wl_caps_*` surface (`wl_provide_completion`/
    /// `wl_caps_item`/…) this slice does NOT touch or migrate (§5.3's
    /// demolition gate is later work) — `.slot` names the NEW generic
    /// surface that coexists beside it by design (§5.3: "the two paths
    /// coexist by DESIGN under a stated demolition date").
    slot,
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
pub const Perm = enum { fs_read, fs_write, net, proc, proc_timer, env };

pub const Entry = struct {
    /// The `weft.<name>` import name — matches the guest's `extern "weft" fn
    /// <name>(..)` in src/guest/weft.zig exactly.
    name: []const u8,
    params: []const ValType,
    results: []const ValType,
    group: Group,
    perm: ?Perm = null,
    /// task #19 item 4: TRUE for an import whose handler MUTATES per-head
    /// interaction state — `Head.zig`'s module doc: mode, pending chord,
    /// pick session, echo line (dot-repeat and window focus have no `wl_*`
    /// door today). `false` — the overwhelming majority — for everything
    /// else, in particular:
    ///   - mode/menu TABLE declarations (`wl_menu_mode`,
    ///     `wl_resting_mode`, `wl_sticky_menu`, `wl_set_fallback`,
    ///     `wl_bind_key`, `wl_text_input`, `wl_declare_action`, `wl_provide`)
    ///     — these declare what a mode/action IS, system-scoped (Keymap
    ///     owns the tables; Head owns only the CURSOR into them — see
    ///     Head.zig's "THE SPLIT"), legal from `init`.
    ///   - buffer/editor-owned state post-W2a (`wl_jump`, `wl_set_selection`,
    ///     `wl_editor_step`, every `wl_edit*`/anchored-range import,
    ///     `wl_flash`, every `wl_style*`/`wl_fold*`/`wl_readonly*`/
    ///     `wl_decorate*`) — cursor/selection/document content live on
    ///     `Editor`, not `Head`; flash/styles/folds are buffer layers.
    ///   - reads of head state (`wl_menu_binding_*`) and callback-local
    ///     values (`wl_pick_outcome_*`) — `on_menu`'s whole job is reading
    ///     `Head` through a BACKGROUND entry to render which-key; outcome
    ///     reads simply report no value outside their callback. Only MUTATION
    ///     is gated, mirroring `requirePerm`'s effects-only scope.
    /// A `true` entry is NOT blanket-denied outside dispatch, though: it is
    /// also legal during the one-time `describe()`/`init()` load handshake
    /// (`WasmPlugin.loading`'s doc) — `wl_set_mode` specifically is exactly
    /// how `vim.zig`/`helix.zig`/`emacs.zig`'s `init()` establishes the
    /// guest's STARTING mode (`weft.setMode("normal")`, its last line), a
    /// real pattern every modal-editor guest uses, discovered by the full
    /// test suite failing when this table's first draft (wrongly) assumed
    /// `init` never needs a head-gated import.
    /// Enforced by `wasm_host/plugin.zig`'s `requireDispatch`, called at the
    /// top of each `true` entry's handler; cross-checked against the actual
    /// call sites by `contract.zig`'s curated `head_gated` test (same shape
    /// as its `perm_gated` test).
    head_gated: bool = false,
    /// One-line human doc — NOT the source of truth for behavior (the
    /// handler body is), just review/generation context.
    doc: []const u8,
};

/// The membrane's host-import DATA table: one entry per `weft.wl_*` import
/// the guest shim declares, minus the handler (see contract.zig, which
/// zips this against `handlers` by name). Add or change an import here
/// (params/results/group/perm/doc), bind its handler in contract.zig's
/// `handlers` list, and mirror the extern's arity+signedness by hand in
/// src/guest/weft.zig — forgetting any of the three now fails a build, not
/// a runtime.
pub const imports = [_]Entry{
    // ── declare.zig — describe-phase declarations ──────────────────────
    .{ .name = "wl_log", .params = &.{ .u32, .u32, .u32 }, .results = &.{}, .group = .declare, .doc = "write a guest log line at `level`" },
    .{ .name = "wl_declare_command", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .declare, .doc = "describe-phase: declare a command name (id assigned on first declare)" },
    .{ .name = "wl_declare_capability", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .declare, .doc = "describe-phase: declare an abstract capability name this plugin provides" },
    .{ .name = "wl_request_perm", .params = &.{.u32}, .results = &.{}, .group = .declare, .doc = "describe-phase: request a permission bit (fs_read/fs_write/net/proc/timer)" },

    // ── edit.zig — read-only, native editor step, write, anchored ranges ─
    .{ .name = "wl_cursor", .params = &.{}, .results = &.{.u32}, .group = .edit, .doc = "the cursor's byte offset in the active document" },
    .{ .name = "wl_byte_len", .params = &.{}, .results = &.{.u32}, .group = .edit, .doc = "the active document's byte length" },
    .{ .name = "wl_doc_snapshot", .params = &.{}, .results = &.{.i32}, .group = .edit, .doc = "capture an opaque causal-frontier witness for the active document" },
    .{ .name = "wl_doc_snapshot_is_current", .params = &.{.u32}, .results = &.{.u32}, .group = .edit, .doc = "test an opaque document witness for equality with the active frontier" },
    .{ .name = "wl_doc_snapshot_release", .params = &.{.u32}, .results = &.{}, .group = .edit, .doc = "release an opaque document frontier witness (idempotent)" },
    .{ .name = "wl_slice", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.u32}, .group = .edit, .doc = "copy `[start,end)` of the active document into guest memory" },
    .{ .name = "wl_line_at", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .edit, .doc = "write the `[start,end)` byte span of the line containing `offset`" },
    .{ .name = "wl_selection", .params = &.{.u32}, .results = &.{.u32}, .group = .edit, .doc = "the active selection's other endpoint (mark), or the cursor if none" },
    .{ .name = "wl_path", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .edit, .doc = "the active buffer's path into guest memory, or -1 if unnamed" },
    .{ .name = "wl_editor_step", .params = &.{ .u32, .u32, .u32 }, .results = &.{.u32}, .group = .edit, .doc = "the pure step primitive a motion composes (char boundary or line motion); no cursor move" },
    .{ .name = "wl_set_selection", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .edit, .doc = "select `[start,end)` (mark at start, cursor at end)" },
    .{ .name = "wl_edit", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .edit, .doc = "the gated edit door: replace `[start,end)` with bytes, authored as the plugin's own peer" },
    .{ .name = "wl_render", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .edit, .doc = "produce derived/streamed content into a buffer, bypassing read-only (output, not user text)" },
    .{ .name = "wl_edit_as", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .edit, .doc = "like `wl_edit` but authored as a named `.agent` sub-peer (its own selective-undo unit)" },
    .{ .name = "wl_jump", .params = &.{.u32}, .results = &.{}, .group = .edit, .doc = "move the cursor to `offset`" },
    .{ .name = "wl_anchor_range", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .edit, .doc = "anchor `[start,end)` in the active CRDT document and return a dispatch-scoped opaque live-range handle" },
    .{ .name = "wl_set_result_range", .params = &.{.u32}, .results = &.{}, .group = .edit, .doc = "set the command result from an anchored live-range handle" },
    .{ .name = "wl_run_range", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .edit, .doc = "run a command by name and import its returned borrowed live range (await-a-motion)" },
    .{ .name = "wl_range_ends", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .edit, .doc = "resolve an anchored live-range handle to its current `[start,end)`" },
    .{ .name = "wl_range_retain", .params = &.{.u32}, .results = &.{.i32}, .group = .edit, .doc = "retain a live-range handle across command dispatches; 0 on success" },
    .{ .name = "wl_range_release", .params = &.{.u32}, .results = &.{}, .group = .edit, .doc = "release one anchored live-range handle (idempotent)" },
    .{ .name = "wl_run_range_arg", .params = &.{ .u32, .u32, .u32 }, .results = &.{}, .group = .edit, .doc = "run a command passing an anchored live range as its single borrowed argument" },
    .{ .name = "wl_arg_range", .params = &.{.u32}, .results = &.{.i32}, .group = .edit, .doc = "import a borrowed live-range command arg into this plugin's anchored range table" },
    .{ .name = "wl_edit_range", .params = &.{ .u32, .u32, .u32 }, .results = &.{}, .group = .edit, .doc = "apply an edit over an anchored live-range handle through the gated edit door" },

    // ── layers.zig — flash/style/fold/readonly/decorate/breakpoints ────
    .{ .name = "wl_flash", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .layers, .doc = "vim-goggles: flash `[start,end)` for the frame loop to fade and the view to draw" },
    .{ .name = "wl_style_clear", .params = &.{}, .results = &.{}, .group = .layers, .doc = "(re)claim the active buffer's styles layer and baseline it to `.normal`" },
    .{ .name = "wl_style", .params = &.{ .u32, .u32, .u32 }, .results = &.{}, .group = .layers, .doc = "paint `[start,end)` of the active buffer's styles bulk with `class`" },
    .{ .name = "wl_fold_clear", .params = &.{}, .results = &.{}, .group = .layers, .doc = "(re)claim the active buffer's fold layer and empty it" },
    .{ .name = "wl_fold", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .layers, .doc = "hide `[start,end)` as an invisible/folded span" },
    .{ .name = "wl_readonly_clear", .params = &.{}, .results = &.{}, .group = .layers, .doc = "(re)claim the active buffer's read-only-span layer and empty it" },
    .{ .name = "wl_readonly_span", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .layers, .doc = "mark `[start,end)` read-only (edit-door defense in depth)" },
    .{ .name = "wl_decorate_clear", .params = &.{}, .results = &.{}, .group = .layers, .doc = "(re)claim the active buffer's decorations layer and empty it" },
    .{ .name = "wl_decorate", .params = &.{ .u32, .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .layers, .doc = "place a display-only decoration (virtual text) anchored at `anchor`" },
    .{ .name = "wl_breakpoint_toggle", .params = &.{.u32}, .results = &.{.i32}, .group = .layers, .doc = "toggle an ANCHORED breakpoint at `offset` in the active document; 1 if now set" },
    .{ .name = "wl_breakpoint_clear", .params = &.{}, .results = &.{}, .group = .layers, .doc = "drop every breakpoint in the active document" },
    .{ .name = "wl_breakpoint_offsets", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .layers, .doc = "the active document's breakpoints as an offset CSV, resolved at the current head" },

    // ── annotate.zig — third-party decoration of a REFERENCED entry (§11.7) ─
    .{ .name = "wl_annotate_open", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .annotate, .doc = "claim annotation layer `name` on entry `id`; an opaque target handle, or -1" },
    .{ .name = "wl_annotate_close", .params = &.{.u32}, .results = &.{}, .group = .annotate, .doc = "drop this provider's annotation layer on that entry (its paint, nothing else)" },
    .{ .name = "wl_annotate_len", .params = &.{.u32}, .results = &.{.i32}, .group = .annotate, .doc = "the decorated entry's byte length at the current head, or -1 when it is gone" },
    .{ .name = "wl_annotate_read", .params = &.{ .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .annotate, .doc = "read `[start,end)` of the decorated entry's text into guest memory" },
    .{ .name = "wl_annotate_begin", .params = &.{.u32}, .results = &.{.i32}, .group = .annotate, .doc = "open a publish round: drop the old set and stamp the entry revision" },
    .{ .name = "wl_annotate_span", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .annotate, .doc = "publish one anchored span with a role and placement into the open round" },

    // ── config_kv.zig — runtime kv scratch + the distinct config store ──
    .{ .name = "wl_kv_get", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .config_kv, .doc = "read this plugin's runtime kv scratch value for `key`" },
    .{ .name = "wl_kv_put", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .config_kv, .doc = "write this plugin's runtime kv scratch value for `key`" },
    .{ .name = "wl_config_get", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .config_kv, .doc = "read this plugin's staged config value (the distinct weft.set store)" },

    // ── dispatch.zig — echo + command args in/result out ───────────────
    .{ .name = "wl_echo", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .dispatch, .head_gated = true, .doc = "print a message to the echo area" },
    .{ .name = "wl_arg_count", .params = &.{}, .results = &.{.u32}, .group = .dispatch, .doc = "the current command dispatch's argument count" },
    .{ .name = "wl_arg_int", .params = &.{.u32}, .results = &.{.i32}, .group = .dispatch, .doc = "the `i`-th dispatch arg as an int" },
    .{ .name = "wl_arg_str", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .dispatch, .doc = "the `i`-th dispatch arg as a string, into guest memory" },
    .{ .name = "wl_set_result_int", .params = &.{.i32}, .results = &.{}, .group = .dispatch, .doc = "set the command result to an int" },
    .{ .name = "wl_set_result_str", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .dispatch, .doc = "set the command result to a string" },

    // ── keymap.zig — the local config plane: bindings/modes/providers ──
    .{ .name = "wl_bind_key", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .keymap, .doc = "bind a key chord in mode `m` to command `c`" },
    .{ .name = "wl_bind_keys", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .keymap, .doc = "bind a key chord in mode `m` to a framed first-applicable intention list (architecture §10.2)" },
    .{ .name = "wl_set_mode", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .keymap, .head_gated = true, .doc = "switch the active buffer's mode" },
    .{ .name = "wl_set_fallback", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .keymap, .doc = "declare mode `m`'s fallback (parent) mode for unbound keys" },
    .{ .name = "wl_text_input", .params = &.{ .u32, .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .keymap, .doc = "declare mode `m`'s text-input command (and whether it takes the typed char)" },
    .{ .name = "wl_menu_mode", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .keymap, .doc = "declare a mode a which-key-style menu" },
    .{ .name = "wl_resting_mode", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .keymap, .doc = "declare a mode a buffer can rest in (`baseMode` stops there)" },
    .{ .name = "wl_exit_to_resting", .params = &.{}, .results = &.{}, .group = .keymap, .head_gated = true, .doc = "leave a transient mode back to the active buffer's resting mode" },
    .{ .name = "wl_resting_posture", .params = &.{ .u32, .u32, .u32 }, .results = &.{}, .group = .keymap, .doc = "declare the mode this grammar rests in for an input posture (§10.4)" },
    .{ .name = "wl_posture", .params = &.{}, .results = &.{.u32}, .group = .keymap, .doc = "how the addressed entry rests under input (§10.4: text/structural/field/capture)" },
    .{ .name = "wl_declare_posture", .params = &.{.u32}, .results = &.{}, .group = .keymap, .head_gated = true, .doc = "declare the addressed entry's input posture, overriding the derivation" },
    .{ .name = "wl_sticky_menu", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .keymap, .doc = "mark a menu mode sticky (stays open after a leaf key)" },
    .{ .name = "wl_declare_action", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .keymap, .doc = "declare an abstract action + its trampoline command" },
    .{ .name = "wl_provide", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32, .i32 }, .results = &.{}, .group = .keymap, .doc = "register a provider for an action, scoped by mode/lang/tool + priority" },

    // ── commands.zig — register/run/introspect ──────────────────────────
    .{ .name = "wl_register", .params = &.{ .u32, .u32 }, .results = &.{.u32}, .group = .commands, .doc = "register-phase: intern a name into this plugin's local command id table" },
    .{ .name = "wl_run", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .commands, .doc = "run a command by name, no args" },
    .{ .name = "wl_run_int", .params = &.{ .u32, .u32, .i32 }, .results = &.{}, .group = .commands, .doc = "run a command by name with one int arg" },
    .{ .name = "wl_run_str", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .commands, .doc = "run a command by name with one string arg" },
    .{ .name = "wl_run_str2", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .commands, .doc = "run a command by name with two string args" },
    .{ .name = "wl_command_count", .params = &.{}, .results = &.{.u32}, .group = .commands, .doc = "the number of registered commands (introspection)" },
    .{ .name = "wl_command_name", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .commands, .doc = "the `i`-th command's name, into guest memory" },
    .{ .name = "wl_command_summary", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .commands, .doc = "the `i`-th command's one-line summary, into guest memory" },

    // ── intent.zig — the focused context's live offers ──────────────────
    .{ .name = "wl_offer_count", .params = &.{}, .results = &.{.u32}, .group = .intent, .doc = "the number of intentions offered in the focused context" },
    .{ .name = "wl_offer_name", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .intent, .doc = "the `i`-th offered intention's name, into guest memory" },
    .{ .name = "wl_offer_provider", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .intent, .doc = "the `i`-th offer's winning provider name, into guest memory" },
    .{ .name = "wl_offer_reason", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .intent, .doc = "why the `i`-th offer cannot run (0 = it can), into guest memory" },
    .{ .name = "wl_intent_invoke", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .intent, .doc = "resolve an intention for the CURRENT context and invoke it through the effect door; writes a refusal reason (0 = invoked, -1 = not an intention)" },
    .{ .name = "wl_offers_begin", .params = &.{ .u32, .u32, .u32 }, .results = &.{.u32}, .group = .intent, .doc = "start this plugin's offer table for a tool identity, stamped with its model ordinal" },
    .{ .name = "wl_offer", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{.u32}, .group = .intent, .doc = "stage one offer row: an intention, one of this plugin's own commands, and the reason it cannot run (empty = enabled)" },
    .{ .name = "wl_offers_commit", .params = &.{}, .results = &.{.u32}, .group = .intent, .doc = "publish the staged table as this plugin's whole offer set" },
    .{ .name = "wl_offers_retract", .params = &.{}, .results = &.{}, .group = .intent, .doc = "withdraw this plugin's offers entirely" },

    // ── buffers.zig — the open-buffer list (introspection) ──────────────
    .{ .name = "wl_buffer_count", .params = &.{}, .results = &.{.u32}, .group = .buffers, .doc = "the number of open buffers" },
    .{ .name = "wl_buffer_id", .params = &.{.u32}, .results = &.{.i32}, .group = .buffers, .doc = "the `i`-th open buffer's id, or -1" },
    .{ .name = "wl_buffer_name", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .buffers, .doc = "the `i`-th open buffer's name, into guest memory" },
    .{ .name = "wl_buffer_active", .params = &.{.u32}, .results = &.{.u32}, .group = .buffers, .doc = "whether the `i`-th buffer is the active one" },
    .{ .name = "wl_buffer_readonly", .params = &.{.u32}, .results = &.{.u32}, .group = .buffers, .doc = "whether the `i`-th buffer is read-only" },

    // ── pick.zig — fuzzy pick build/open/accept ─────────────────────────
    .{ .name = "wl_pick_begin", .params = &.{ .u32, .u32, .u32 }, .results = &.{}, .group = .pick, .doc = "start building a fuzzy pick with `prompt`, tagged `pick_id`" },
    .{ .name = "wl_pick_add", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .pick, .doc = "add a candidate (text, detail) to the pick being built" },
    .{ .name = "wl_pick_add_buffer", .params = &.{ .u32, .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .pick, .doc = "add a candidate carrying the `i`-th buffer's identity as its accept key" },
    .{ .name = "wl_pick_end", .params = &.{}, .results = &.{}, .group = .pick, .head_gated = true, .doc = "open the pick built so far" },
    .{ .name = "wl_open_file_pick", .params = &.{ .u32, .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .pick, .head_gated = true, .doc = "open a file-tree pick rooted at `root`" },
    .{ .name = "wl_pick_outcome_kind", .params = &.{}, .results = &.{.i32}, .group = .pick, .doc = "callback-scoped pick outcome: 0 cancelled, 1 input, 2 candidate, -1 outside callback" },
    .{ .name = "wl_pick_outcome_text", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .pick, .doc = "exact callback-scoped accepted text; cap=0 reports length, short destinations return -2" },
    .{ .name = "wl_pick_outcome_query", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .pick, .doc = "exact accepted-candidate query; cap=0 reports length, short destinations return -2" },
    .{ .name = "wl_pick_outcome_index", .params = &.{}, .results = &.{.i32}, .group = .pick, .doc = "the accepted candidate's add-order identity, or -1" },
    .{ .name = "wl_pick_outcome_buffer", .params = &.{}, .results = &.{.i32}, .group = .pick, .doc = "the live id of the buffer the accepted candidate named, or -1 when it is gone or unkeyed" },
    .{ .name = "wl_pick_outcome_match_start", .params = &.{}, .results = &.{.i32}, .group = .pick, .doc = "the accepted candidate's candidate-relative byte match start, or -1" },
    .{ .name = "wl_pick_outcome_match_span", .params = &.{}, .results = &.{.i32}, .group = .pick, .doc = "the accepted candidate's byte match span, or -1" },

    // ── menu.zig — which-key style menu-mode binding introspection ─────
    .{ .name = "wl_menu_binding_count", .params = &.{}, .results = &.{.i32}, .group = .menu, .doc = "the current menu mode's binding-table entry count" },
    .{ .name = "wl_menu_binding_key", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .menu, .doc = "the `i`-th menu binding's key chord, into guest memory" },
    .{ .name = "wl_menu_binding_cmd", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .menu, .doc = "the `i`-th menu binding's command name, into guest memory" },
    .{ .name = "wl_menu_binding_is_group", .params = &.{.u32}, .results = &.{.i32}, .group = .menu, .doc = "whether the `i`-th menu binding is a group (submenu), not a leaf" },
    .{ .name = "wl_menu_binding_intent_status", .params = &.{.u32}, .results = &.{.i32}, .group = .menu, .doc = "what the `i`-th binding's intention arms would do here: 0 none, 1 ready, 2 unavailable" },
    .{ .name = "wl_menu_binding_intent", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .menu, .doc = "the `i`-th binding's winning (or blocked) intention name, into guest memory" },
    .{ .name = "wl_menu_binding_intent_note", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .menu, .doc = "the provider that would run the `i`-th binding, or the reason it cannot" },

    // ── surface.zig — the retained overlay (which-key/files/git) ─────
    .{ .name = "wl_surface_begin", .params = &.{.u32}, .results = &.{}, .group = .surface, .doc = "open a retained overlay surface at `placement`" },
    .{ .name = "wl_surface_caret", .params = &.{.u32}, .results = &.{}, .group = .surface, .doc = "open a retained overlay surface anchored at document offset `offset` (rendering P2)" },
    .{ .name = "wl_surface_row", .params = &.{}, .results = &.{}, .group = .surface, .doc = "start a new row in the open surface" },
    .{ .name = "wl_surface_span", .params = &.{ .u32, .u32, .u32 }, .results = &.{}, .group = .surface, .doc = "append a styled text span to the current surface row" },
    .{ .name = "wl_surface_end", .params = &.{.i32}, .results = &.{}, .group = .surface, .doc = "close the open surface, marking a row selected or not" },
    .{ .name = "wl_surface_close", .params = &.{}, .results = &.{}, .group = .surface, .doc = "close the surface without a selection" },

    // ── capability.zig — the completion provider gather/push ───────────
    .{ .name = "wl_provide_completion", .params = &.{}, .results = &.{}, .group = .capability, .doc = "caps trampoline: hand the guest the pending completion session" },
    .{ .name = "wl_completion_prefix", .params = &.{ .u32, .u32 }, .results = &.{.u32}, .group = .capability, .doc = "the current completion prefix, into guest memory" },
    .{ .name = "wl_caps_item", .params = &.{ .i32, .u32, .u32, .u32, .u32, .u32, .u32, .i32, .u32, .u32, .i32 }, .results = &.{}, .group = .capability, .doc = "append one rich completion item to the plugin's pending batch" },
    .{ .name = "wl_caps_commit", .params = &.{.i32}, .results = &.{}, .group = .capability, .doc = "flush the pending completion batch into the session" },
    .{ .name = "wl_caps_decline", .params = &.{.i32}, .results = &.{}, .group = .capability, .doc = "decline to answer a completion session" },

    // ── syntax.zig — structural (tree-sitter) read + subbuffers ────────
    .{ .name = "wl_node_at", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .syntax, .doc = "the smallest named tree-sitter node covering `offset`" },
    .{ .name = "wl_node_enclosing", .params = &.{ .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .syntax, .doc = "the smallest named node strictly enclosing `[start,end)` (expand-selection)" },
    .{ .name = "wl_query", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .syntax, .doc = "run a tree-sitter query over `[start,end)`, stashing its captures" },
    .{ .name = "wl_query_capture", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .syntax, .doc = "read the `i`-th capture from the last `wl_query`/`wl_node_children`" },
    .{ .name = "wl_node_children", .params = &.{.u32}, .results = &.{.i32}, .group = .syntax, .doc = "the named children of the smallest node at `off` (structural descent)" },
    .{ .name = "wl_claim_subbuffer", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .syntax, .doc = "claim `[start,end)` as a subbuffer (a projection row's hidden identity)" },
    .{ .name = "wl_subbuffer_put_fact", .params = &.{ .u32, .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .syntax, .doc = "attach a key/value fact to a claimed subbuffer" },
    .{ .name = "wl_subbuffer_clear", .params = &.{}, .results = &.{}, .group = .syntax, .doc = "release every subbuffer this plugin claimed" },
    .{ .name = "wl_subbuffer_fact_at", .params = &.{ .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .syntax, .doc = "read fact `key` off the innermost subbuffer covering `offset`" },

    // ── activation.zig — the focus event ────────────────────────────────
    .{ .name = "wl_activate_path", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .activation, .doc = "the path of the buffer taking focus (host→guest activation, borrowed)" },

    // ── tool.zig — projection ownership ─────────────────────────────────
    .{ .name = "wl_tool_backing", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .tool, .doc = "mark the active buffer as this plugin's tool projection" },

    // ── register.zig — the editor-agnostic yank/paste service ──────────
    .{ .name = "wl_yank_range", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .register, .doc = "capture `[start,end)` into an explicit register slot" },
    .{ .name = "wl_register_text", .params = &.{ .u32, .u32, .u32 }, .results = &.{.u32}, .group = .register, .doc = "read an explicit register slot's bytes into guest memory" },
    .{ .name = "wl_register_linewise", .params = &.{.u32}, .results = &.{.u32}, .group = .register, .doc = "whether an explicit register slot holds a linewise yank" },
    .{ .name = "wl_paste_at", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .register, .doc = "re-claim an explicit register slot's payloads over inserted text" },

    // ── semantic.zig — tool-neutral focused-view actions ───────────────
    .{ .name = "wl_semantic_active", .params = &.{}, .results = &.{.u32}, .group = .semantic, .doc = "whether this head currently focuses a live semantic view" },
    .{ .name = "wl_semantic_working_target", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .head_gated = true, .doc = "copy this head's validated exact working target, return zero when absent" },
    .{ .name = "wl_semantic_view_focus", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .head_gated = true, .doc = "attach a live semantic view to this head, using an optional canonical u64 NodeId preference" },
    .{ .name = "wl_semantic_interaction_open", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .head_gated = true, .doc = "decode and open a bounded interaction definition on this head, writing its typed ref" },
    .{ .name = "wl_semantic_interaction_close", .params = &.{ .u32, .u32, .u32 }, .results = &.{.u32}, .group = .semantic, .head_gated = true, .doc = "close the active head-local interaction named by a typed ref" },
    .{ .name = "wl_semantic_action", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .head_gated = true, .doc = "invoke an open action with an explicit transfer-register slot" },
    .{ .name = "wl_semantic_target_publish", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "admit a canonical target definition and write its typed handle" },
    .{ .name = "wl_semantic_target_replace", .params = &.{ .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "replace an owned target definition without changing its identity" },
    .{ .name = "wl_semantic_target_close", .params = &.{ .u32, .u32, .u32 }, .results = &.{.u32}, .group = .semantic, .doc = "close an owned target and invalidate its generation" },
    .{ .name = "wl_semantic_target_describe_len", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "return the bounded canonical descriptor snapshot length for a live target" },
    .{ .name = "wl_semantic_target_describe", .params = &.{ .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "copy a bounded canonical descriptor snapshot for a live target" },
    .{ .name = "wl_semantic_view_publish", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "admit a canonical semantic scene and write its typed view handle" },
    .{ .name = "wl_semantic_view_replace", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "replace an owned retained scene at an explicit revision" },
    .{ .name = "wl_semantic_view_close", .params = &.{ .u32, .u32, .u32 }, .results = &.{.u32}, .group = .semantic, .doc = "close an owned view and invalidate its generation" },
    .{ .name = "wl_semantic_field_register", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "register a tokenized host-retained editable field snapshot and write its typed handle" },
    .{ .name = "wl_semantic_field_update", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "replace an owned field snapshot at a distinct provider revision" },
    .{ .name = "wl_semantic_field_close", .params = &.{ .u32, .u32, .u32 }, .results = &.{.u32}, .group = .semantic, .doc = "close an owned field endpoint and invalidate its generation" },
    .{ .name = "wl_semantic_field_edit_meta", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "host-to-guest callback read: fixed metadata for the current field edit" },
    .{ .name = "wl_semantic_field_edit_revision", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "host-to-guest callback read: exact expected field revision bytes" },
    .{ .name = "wl_semantic_field_edit_replacement", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "host-to-guest callback read: exact replacement bytes for the current field edit" },
    .{ .name = "wl_semantic_action_provider", .params = &.{}, .results = &.{.i32}, .group = .semantic, .doc = "register this owner as a semantic action provider" },
    .{ .name = "wl_semantic_action_request_len", .params = &.{}, .results = &.{.i32}, .group = .semantic, .doc = "host-to-guest callback read: byte length of the current canonical action request" },
    .{ .name = "wl_semantic_action_request", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "host-to-guest callback read: copy the current canonical action request" },
    .{ .name = "wl_semantic_action_respond", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "answer the current action once: declined, handled, canonical transfer/interaction/target, same-view focus, relation, or working-target request" },
    .{ .name = "wl_semantic_target_handler_register", .params = &.{ .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "register a tokenized owner-scoped target handler and write its typed handle" },
    .{ .name = "wl_semantic_target_handler_close", .params = &.{ .u32, .u32, .u32 }, .results = &.{.u32}, .group = .semantic, .doc = "close an owned target handler and invalidate its generation" },
    .{ .name = "wl_semantic_target_handler_request_len", .params = &.{}, .results = &.{.i32}, .group = .semantic, .doc = "host-to-guest callback read: byte length of the current canonical descriptor or located target" },
    .{ .name = "wl_semantic_target_handler_request", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "host-to-guest callback read: copy the current canonical target-handler request" },
    .{ .name = "wl_semantic_target_handler_probe_respond", .params = &.{.u32}, .results = &.{.i32}, .group = .semantic, .doc = "answer one target probe with no claim, a match strength, or a typed failure" },
    .{ .name = "wl_semantic_target_handler_open_respond", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "answer one target open with a typed view handle or typed failure" },
    .{ .name = "wl_semantic_relation_provider_register", .params = &.{ .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "register a tokenized owner-scoped relation provider and write its typed handle" },
    .{ .name = "wl_semantic_relation_provider_close", .params = &.{ .u32, .u32, .u32 }, .results = &.{.u32}, .group = .semantic, .doc = "close an owned relation provider and invalidate its generation" },
    .{ .name = "wl_semantic_relation_request_len", .params = &.{}, .results = &.{.i32}, .group = .semantic, .doc = "host-to-guest callback read: byte length of the current canonical relation query" },
    .{ .name = "wl_semantic_relation_request", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "host-to-guest callback read: copy the current canonical relation query" },
    .{ .name = "wl_semantic_relation_respond", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "answer one relation query with no edge, a canonical located edge, or a typed failure" },
    .{ .name = "wl_semantic_transfer_capture", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .perm = .fs_read, .doc = "capture an authorized filesystem entry into an owner-scoped semantic transfer attachment" },
    .{ .name = "wl_semantic_transfer_retain", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "retain an owner-scoped semantic transfer attachment" },
    .{ .name = "wl_semantic_transfer_release", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .semantic, .doc = "release an owner-scoped semantic transfer attachment" },

    // ── proc.zig — perm-gated off-thread process effects ───────────────
    .{ .name = "wl_shell_insert", .params = &.{ .u32, .u32 }, .results = &.{}, .group = .proc, .perm = .proc_timer, .doc = "run `<cmd>` off-thread and insert its stdout at the cursor when done" },
    .{ .name = "wl_proc_spawn", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .proc, .perm = .proc, .doc = "spawn a persistent subprocess; its stdout buffers for `wl_proc_read`" },
    .{ .name = "wl_proc_send", .params = &.{ .u32, .u32, .u32 }, .results = &.{}, .group = .proc, .doc = "write to a spawned subprocess's stdin" },
    .{ .name = "wl_proc_read", .params = &.{ .u32, .u32, .u32 }, .results = &.{.i32}, .group = .proc, .doc = "drain buffered stdout from a spawned subprocess" },
    .{ .name = "wl_proc_close", .params = &.{.u32}, .results = &.{}, .group = .proc, .doc = "kill a spawned subprocess (slot stays for handle stability)" },
    .{ .name = "wl_place_root", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .proc, .doc = "the dispatching place's absolute directory, or 0 bytes when it has none locally" },
    .{ .name = "wl_place_id", .params = &.{}, .results = &.{.i32}, .group = .proc, .doc = "a dense opaque id for the dispatching place; compare it, never interpret it" },
    .{ .name = "wl_env_publish", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .proc, .perm = .env, .doc = "publish this plugin's environment overlay (NUL-separated KEY=VALUE) for the dispatching place" },
    .{ .name = "wl_env_retract", .params = &.{}, .results = &.{.i32}, .group = .proc, .perm = .env, .doc = "withdraw this plugin's environment overlay for the dispatching place" },
    .{ .name = "wl_proc_to_buffer", .params = &.{ .u32, .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .proc, .perm = .proc_timer, .doc = "run `<cmd>` off-thread and replace the scratch buffer captured now with its stdout; the trailing fill token comes back as `on_fill_token`" },
    .{ .name = "wl_proc_append_buffer", .params = &.{ .u32, .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .proc, .perm = .proc_timer, .doc = "like `wl_proc_to_buffer` but appends (a console log) instead of replacing" },
    .{ .name = "wl_proc_spool", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .proc, .perm = .proc_timer, .doc = "like `wl_proc_to_buffer`, but write `<input>` to a HOST-NAMED temp file, substitute it for `{}` in `<cmd>`, and delete it afterwards — a subprocess gets a real path without the guest holding fs_write" },
    .{ .name = "wl_proc_filter", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .proc, .perm = .proc_timer, .doc = "filter `[start,end)` through `<cmd>` in place (formatters)" },

    // ── sessions.zig — persistent streamed REPL + net sessions ─────────
    .{ .name = "wl_repl_start", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .sessions, .perm = .proc_timer, .doc = "start a persistent REPL streaming into a named comint buffer" },
    .{ .name = "wl_repl_send", .params = &.{ .u32, .u32, .u32 }, .results = &.{}, .group = .sessions, .doc = "write a line to a REPL session's stdin" },
    .{ .name = "wl_repl_quit", .params = &.{.u32}, .results = &.{}, .group = .sessions, .doc = "quit a REPL session (kill+join; handle stays valid but dead)" },
    .{ .name = "wl_net_connect", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .sessions, .perm = .net, .doc = "dial `host:port` (TCP/TLS), streaming into a named buffer" },
    .{ .name = "wl_net_send", .params = &.{ .u32, .u32, .u32 }, .results = &.{}, .group = .sessions, .doc = "write bytes to a connected net session" },
    .{ .name = "wl_net_close", .params = &.{.u32}, .results = &.{}, .group = .sessions, .doc = "close a net session" },

    // ── fs.zig — perm-gated local filesystem doors ─────────────────────
    .{ .name = "wl_fs_read", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .fs, .perm = .fs_read, .doc = "read a file into the guest" },
    .{ .name = "wl_fs_exists", .params = &.{ .u32, .u32 }, .results = &.{.i32}, .group = .fs, .perm = .fs_read, .doc = "what a cwd-relative path is (absent/file/dir/other), without reading it" },
    .{ .name = "wl_fs_write", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .fs, .perm = .fs_write, .doc = "replace a file's contents" },
    .{ .name = "wl_fs_append", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .fs, .perm = .fs_write, .doc = "append to a file (capture)" },
    .{ .name = "wl_fs_list", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .fs, .perm = .fs_read, .doc = "list a local directory (locus-routed; remote authorities degrade to -1)" },
    .{ .name = "wl_fs_list_async", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .fs, .perm = .fs_read, .doc = "queue an async `.peer` directory listing, delivered to a buffer" },
    .{ .name = "wl_semantic_fs_publish_child_directory", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .fs, .perm = .fs_read, .doc = "derive and publish one provider-confined direct child directory from a canonical guarded request" },
    .{ .name = "wl_semantic_fs_publish_child_file", .params = &.{ .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .fs, .perm = .fs_read, .doc = "publish one provider-guarded direct child ordinary file from a canonical guarded request" },
    .{ .name = "wl_semantic_fs_capabilities", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .fs, .perm = .fs_read, .doc = "query provider capabilities for a live semantic target revision" },
    .{ .name = "wl_semantic_fs_list", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .fs, .perm = .fs_read, .doc = "list the filesystem directory attached to a live semantic target revision" },
    .{ .name = "wl_semantic_fs_apply", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{.i32}, .group = .fs, .perm = .fs_write, .doc = "apply a bounded typed filesystem plan against a live semantic target revision" },

    // ── slot.zig — D2's generic, schema-directed membrane verbs ────────
    // (doc/d2-schema-payloads.md §3.2). These four carry `(SchemaRef
    // version, ptr, len)` scalars only — `schema.zig` interprets the
    // `(ptr,len)` bytes against the slot's declared schema; this table
    // stays ignorant of what's inside them, exactly like every other bulk
    // `(ptr,len)` import here.
    // DEVIATION from doc/d2-schema-payloads.md §3.2's literal 4-param
    // listing, disclosed in the D2 slice report: `Container.declareSlot`
    // requires `shape`/`composition` (no defaults) and the RUNTIME verb has
    // no OTHER channel to supply them (unlike `weft.slot`'s JS literal,
    // which carries them as named fields) — extended to 6 params rather
    // than hardcoding a shape/composition every runtime-declared slot would
    // be stuck with.
    .{ .name = "wl_slot_declare", .params = &.{ .u32, .u32, .u32, .u32, .u32, .u32 }, .results = &.{}, .group = .slot, .doc = "runtime-declare a slot: name + shape + composition + its canonical schema blob (schema.canonicalizeSchema's wire form)" },
    .{ .name = "wl_slot_bind", .params = &.{ .u32, .u32, .u32, .u32, .u32, .i32 }, .results = &.{}, .group = .slot, .doc = "bind a provider for an already-declared slot, gated by a predicate blob, at priority" },
    .{ .name = "wl_payload_push", .params = &.{ .i32, .u32, .u32, .u32 }, .results = &.{}, .group = .slot, .doc = "push one schema-encoded payload (SchemaRef version + bytes) for a fired slot session" },
    .{ .name = "wl_payload_read", .params = &.{ .i32, .u32, .u32 }, .results = &.{.i32}, .group = .slot, .doc = "host->guest: fill a guest scratch buffer with a fired session's schema-encoded request payload" },
};

/// The imports table's size, alongside `imports.len`, as a deliberate
/// tripwire: bump this BY HAND alongside adding or removing a contract entry
/// (and its guest extern in src/guest/weft.zig — see the comptime
/// verification block in that file for what happens if you forget), so an
/// accidental add/remove — a merge conflict, a copy-paste slip, a
/// half-finished edit — fails the build with a pointed message instead of
/// silently drifting the two ~124-entry tables apart again (the exact class
/// this table exists to kill).
const expected_import_count = 208;

/// A host→guest EXPORT entrypoint (design doc/extensibility-native-surface.md, task
/// W0a-D extension 2): every `instance.callVoid("name", args)` the host
/// tree fires INTO a loaded guest, named once here instead of as a bare
/// string literal at each call site. `required = true` means the guest is
/// expected to provide this export — a missing one is a genuine load/dispatch
/// failure, not tolerated. `required = false` means a guest may omit it; the
/// call site decides what "omitted" means for it (skip silently, treat as
/// declined, etc — the exact per-site reaction is NOT uniform today, and
/// unifying it is out of scope: doing so would be a behavior change, and
/// this task is zero-behavior-change). What the table DOES centralize: the
/// (name, arity, required) triple, checked at the call site by the typed
/// helpers in contract.zig (`callRequiredExport`/`callOptionalExport`) — a
/// call site can no longer name an export this table doesn't know about, or
/// use the wrong helper for its required-ness, without a compile error.
///
/// Guest-side note: unlike `imports`, this table has NO guest-side
/// counterpart to verify against — a guest's `export fn on_command(id: u32)
/// void {..}` lives in per-plugin source (src/guest/*.zig, not weft.zig's
/// SDK), and its signature crosses the wasm boundary where Zig's comptime
/// cannot reach (the guest may not even be Zig — see quickjs.zig). That
/// boundary is a REAL limit stated up front, not fudged.
pub const Export = struct {
    name: []const u8,
    params: []const ValType,
    results: []const ValType,
    required: bool,
    doc: []const u8,
};

/// The ~10 entrypoints a loaded guest may export, inventoried from every
/// `instance.callVoid`/`callI32` call site across src/core/wasm_abi/* and
/// src/core/wasm_host/* (quickjs.zig's OWN `instance.call*` — loading the
/// qjs.wasm blob itself, e.g. "_initialize"/"malloc"/"weft_eval" — is a
/// different transport layer, not a `weft.*` guest plugin export, and stays
/// out of this table; see qjs_contract.zig for its own surface).
pub const exports = [_]Export{
    .{ .name = "describe", .params = &.{}, .results = &.{}, .required = false, .doc = "describe-phase: declare commands/capabilities/perms (no authority yet); a static-manifest guest may omit it" },
    .{ .name = "init", .params = &.{}, .results = &.{}, .required = true, .doc = "register commands/keymap/etc, cross-checked against describe()'s declarations" },
    .{ .name = "run", .params = &.{}, .results = &.{}, .required = true, .doc = "the milestone-2 minimal-ABI entrypoint (runGuest's one-shot guest, not the full plugin lifecycle)" },
    .{ .name = "on_command", .params = &.{.i32}, .results = &.{}, .required = true, .doc = "dispatch a registered command by id; args/result cross via wl_arg_*/wl_set_result_*" },
    .{ .name = "on_complete", .params = &.{.i32}, .results = &.{}, .required = false, .doc = "answer a completion session (handle); missing/trapped -> the host declines it" },
    .{ .name = "on_pick_accept", .params = &.{.i32}, .results = &.{}, .required = true, .doc = "a fuzzy pick this plugin opened was accepted, tagged by pick_id" },
    .{ .name = "on_menu", .params = &.{.i32}, .results = &.{}, .required = false, .doc = "a menu mode this plugin owns was entered (1) or left (0)" },
    .{ .name = "on_activate", .params = &.{}, .results = &.{}, .required = false, .doc = "a buffer took focus (path readable via wl_activate_path during the call)" },
    .{ .name = "on_poll", .params = &.{}, .results = &.{}, .required = false, .doc = "readiness-driven: fired only when this plugin's raw proc stream has bytes pending" },
    .{ .name = "on_fill_token", .params = &.{.i32}, .results = &.{}, .required = false, .doc = "the fill with this token landed in the entry it captured at spawn; a chance to parse and paint it" },
    // D2's generic slot-fire dispatch (doc/d2-schema-payloads.md §3.2/§7):
    // the schema-directed sibling of `on_complete` — a schema-provider
    // guest answers `session` by calling `wl_payload_push` (during this
    // call, or later off a poll, mirroring `on_complete`'s sync/async
    // split) or `wl_payload_read`s the fired request first. Host→guest
    // DISPATCH stays call-based (§7: "a schema marshals DATA, never
    // function pointers"); only the PAYLOAD crossing it carries is
    // schema-directed.
    .{ .name = "on_slot_fire", .params = &.{.i32}, .results = &.{}, .required = false, .doc = "answer a schema-carrying slot session (handle); push via wl_payload_push during this call or later off a poll" },
    .{ .name = "on_semantic_field_edit", .params = &.{.i32}, .results = &.{}, .required = false, .doc = "answer one tokenized semantic field edit by synchronously pushing a new snapshot" },
    .{ .name = "on_semantic_action", .params = &.{}, .results = &.{}, .required = false, .doc = "answer one semantic action synchronously using the current canonical request" },
    .{ .name = "on_semantic_target_probe", .params = &.{.i32}, .results = &.{}, .required = false, .doc = "probe one immutable target descriptor for a tokenized handler" },
    .{ .name = "on_semantic_target_open", .params = &.{.i32}, .results = &.{}, .required = false, .doc = "open one revision-stamped located target through a tokenized handler" },
    .{ .name = "on_semantic_target_settle", .params = &.{ .i32, .i32, .i32, .i32, .i32 }, .results = &.{}, .required = false, .doc = "settle one provisional target view after core admission and focus" },
    .{ .name = "on_semantic_relation_query", .params = &.{.i32}, .results = &.{}, .required = false, .doc = "answer one tokenized named-relation query synchronously" },
};

const expected_export_count = 17;

comptime {
    @setEvalBranchQuota(50_000); // the O(n²) duplicate-name scans below, n≈124
    if (imports.len != expected_import_count) @compileError(std.fmt.comptimePrint(
        "core/membrane/contract_data.zig: imports table has {d} entries, expected {d}. " ++
            "If you added or removed a wl_* host import, update `expected_import_count` here. " ++
            "The guest extern in src/guest/weft.zig still needs adding/removing by hand (Zig " ++
            "can't synthesize a top-level decl from this table) — but forgetting it now fails " ++
            "the BUILD (weft.zig's comptime verification block), not silently.",
        .{ imports.len, expected_import_count },
    ));
    for (imports, 0..) |a, i| {
        if (!std.mem.startsWith(u8, a.name, "wl_"))
            @compileError("core/membrane/contract_data.zig: '" ++ a.name ++ "' doesn't look like a wl_* import");
        if (a.params.len > 16)
            @compileError("core/membrane/contract_data.zig: '" ++ a.name ++ "' has more params than wasm.zig's trampoline can carry (16)");
        if (a.results.len > 8)
            @compileError("core/membrane/contract_data.zig: '" ++ a.name ++ "' has more results than wasm.zig's trampoline can carry (8)");
        for (imports[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name))
                @compileError("core/membrane/contract_data.zig: duplicate wl_* import name '" ++ a.name ++ "'");
        }
    }
    if (exports.len != expected_export_count) @compileError(std.fmt.comptimePrint(
        "core/membrane/contract_data.zig: exports table has {d} entries, expected {d}. " ++
            "If you added a new host->guest call site (instance.callVoid/callI32 into a " ++
            "loaded guest), add its (name, params, required) here and update " ++
            "`expected_export_count` — the call site itself now only compiles through " ++
            "contract.zig's typed helpers, which require a matching entry.",
        .{ exports.len, expected_export_count },
    ));
    for (exports, 0..) |a, i| {
        if (a.params.len > 16)
            @compileError("core/membrane/contract_data.zig: export '" ++ a.name ++ "' has more params than the trampoline can carry (16)");
        for (exports[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name))
                @compileError("core/membrane/contract_data.zig: duplicate export name '" ++ a.name ++ "'");
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────
const t = std.testing;

test "membrane contract data: every import entry is well-formed, documented, and unique" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(t.allocator);
    for (imports) |entry| {
        try t.expect(std.mem.startsWith(u8, entry.name, "wl_"));
        try t.expect(entry.doc.len > 0);
        try t.expect(entry.params.len <= 16 and entry.results.len <= 8);
        const gop = try seen.getOrPut(t.allocator, entry.name);
        try t.expect(!gop.found_existing);
    }
    try t.expectEqual(@as(usize, expected_import_count), imports.len);
}

test "membrane contract data: exactly one door answers WHERE, and it is place-shaped" {
    // The membrane used to answer "where does this run" with the process's
    // launch directory — ONE value fixed at startup, handed to every guest that
    // asked, with no relation to what the dispatch was about. Its four
    // consumers each meant something narrower by it (a language server's
    // workspace, a `.git` climb's floor, a file browser's root), and with two
    // projects open at once the single answer was wrong for at least one of
    // them. `wl_place_root` answers WHERE THIS DISPATCH IS instead, and answers
    // nothing at all when that place has no local directory, so a guest
    // declines rather than acting in the launch directory (`doc/place.md`).
    //
    // This is the positive half of the gate: the replacement is bound, in the
    // proc group beside the spawn doors that read the same place host-side. The
    // ABSENCE of the retired process-directory door — in this table, in the
    // handler list, and in the guest shim — is gated over the real source tree
    // by `e2e/demolition_test.zig`, which is the only file allowed to spell it.
    var saw_place_root = false;
    for (imports) |entry| {
        if (!std.mem.eql(u8, entry.name, "wl_place_root")) continue;
        saw_place_root = true;
        try t.expectEqual(Group.proc, entry.group);
        try t.expectEqual(@as(?Perm, null), entry.perm); // narrower than what it replaced; no new authority
    }
    try t.expect(saw_place_root);
}

test "membrane contract data: every export entry is well-formed, documented, and unique" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(t.allocator);
    for (exports) |entry| {
        try t.expect(entry.name.len > 0);
        try t.expect(entry.doc.len > 0);
        const gop = try seen.getOrPut(t.allocator, entry.name);
        try t.expect(!gop.found_existing);
    }
    try t.expectEqual(@as(usize, expected_export_count), exports.len);
}
