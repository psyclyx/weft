//! core/membrane/qjs_contract.zig — the `qjs_*` import table
//! `src/core/quickjs.zig` binds onto quickjs.wasm's Linker, walked at THREE
//! registration sites (`defineConfigFns`'s config-plane imports, `evalConfig`'s
//! plugin-plane stubs, `JsPlugin.load`'s plugin-plane real handlers) that must
//! all agree on every name's arity.
//!
//! This is an IMPORT NAME TABLE, not a second membrane. It used to describe
//! itself as the `weft.*` membrane's "third surface", and for the plugin plane
//! that was a real problem, not a turn of phrase: `quickjs.wasm` IS a wasm
//! plugin, so a JS plugin is code running inside a wasm guest and must not be
//! able to do anything a wasm guest cannot — yet `qjs_proc_spawn` grew a `cwd`
//! argument `wl_proc_spawn` never had, because there were two bodies to grow it
//! in. There are not any more. The proc doors' four bodies live ONCE, in
//! `wasm_host/proc.zig`, and both membranes are generated from its `doors`
//! table (`e2e/demolition_test.zig` proves it by function pointer, doc/place.md
//! §4.1a). What survives here for those names is the wasm-level import NAME and
//! arity — which must stay distinct from `wl_*` only because quickjs.wasm's C
//! shim bakes the name into the binary's import section.
//!
//! The `.config` group is a different matter and stays its own surface on
//! purpose: config is a distinct ROLE with its own trust tier — it already
//! chooses which plugins load — not a different kind of plugin. Several of its
//! names collide with a `wl_*` door while meaning something else entirely
//! (`qjs_semantic_action` DECLARES a command; `wl_semantic_action` INVOKES
//! one). That is a naming problem, not a capability one.
//!
//! Same `Entry`-data shape as `contract_data.zig` (name/params/results/
//! group/doc), deliberately NOT unified with it: this is a different
//! marshalling path (QuickJS-ng's own C shim, `src/quickjs/weft_qjs.c`,
//! calls these — not a Zig guest with externs to verify), and the plugin-
//! plane names are bound to TWO different handler sets depending on
//! context (generic reject-stubs on the config linker, real handlers on a
//! resident JS plugin's linker) — a shape contract.zig's single
//! `imports`/`handlers` zip doesn't need to express. `ValType` here is
//! `i32` only (no guest-source signedness to transcribe: the C shim's
//! actual parameter types live in weft_qjs.c, outside this codebase's Zig
//! type system, so tracking a signedness this table can't verify against
//! anything would be decoration, not a tripwire).
//!
//! `group` splits the table exactly where quickjs.zig's real registration
//! boundary falls: `.config` entries are bound (with real handlers) on
//! BOTH the config-eval linker and a JS plugin's linker (`defineConfigFns`,
//! called from both `evalConfig` and `JsPlugin.load`); `.plugin` entries
//! are bound with STUB handlers on the config linker (never called there —
//! quickjs.wasm imports them all as one shared binary) and REAL handlers on
//! a JS plugin's linker. quickjs.zig's three registration loops walk this
//! table filtered by group instead of hand-listing `linker.defineFn` calls.

const std = @import("std");

pub const ValType = enum { i32 };

/// The result an i32-returning EFFECT import answers when the calling plugin
/// holds no grant for the capability it needs (`quickjs.zig`'s `denyPerm`).
/// Distinct from `-1`/`0` — those are mundane failures a plugin may ignore —
/// because denial must never be success-shaped: `weft_qjs.c` turns this
/// exact value into a thrown JS exception at the `weft.*` call site
/// (`WEFT_DENIED` there; the two numbers must agree).
pub const denied: i32 = -2;

/// Which linker(s) an entry is bound on. `.config` — the `weft.*` calls every
/// config/plugin script can make (bind/run/echo/log/plugin/use/set/menu/action/
/// provide/statusSegment/grant/viewport/present) — real handlers always, and
/// the one group that is legitimately its own surface (see the module doc).
/// `.plugin` — the calls only a RESIDENT JS plugin makes (register/proc/buffer/
/// transcript/config/breakpoints/fileRead/fileWrite/lineText/activeBuffer/pick/
/// status); stubbed on the config-eval linker (present to satisfy quickjs.wasm's
/// shared import list, never actually called there), real on a plugin's linker.
///
/// A `.plugin` entry is NOT licence for a second implementation. Where a `wl_*`
/// door of the same meaning exists, this name must reach that door's body:
///   - `proc_spawn`/`proc_send`/`proc_read`/`proc_close` — DONE, one body each
///     in `wasm_host/proc.zig`, gated by `e2e/demolition_test.zig`.
///   - `file_read`/`file_write` — the fs POLICY half (possession + `.fs_root`
///     confinement) is already `wasm_host/fs.zig`'s, shared verbatim; the
///     effect half legitimately differs (these author a buffer edit as the
///     agent peer, `wl_fs_*` touch the disk).
///   - `register` — same name as `wl_register`, two different local id
///     registries and two different command trampolines; see `cRegister`.
/// The rest (buffer_*/transcript_*/config/breakpoints/line_text/
/// active_buffer/pick/status) have no same-name `wl_*` door to collapse onto.
pub const Group = enum { config, plugin };

pub const Entry = struct {
    /// The `weft.<name>` import name — matches a `try linker.defineFn("weft",
    /// name, ...)` call in src/core/quickjs.zig exactly.
    name: []const u8,
    params: []const ValType,
    results: []const ValType,
    group: Group,
    /// One-line human doc — review/generation context, not the source of
    /// behavior truth (the handler body is).
    doc: []const u8,
};

fn words(comptime n: usize) []const ValType {
    comptime var arr: [n]ValType = @splat(.i32);
    return &arr;
}

fn e(name: []const u8, comptime np: usize, comptime nr: usize, group: Group, doc: []const u8) Entry {
    return .{ .name = name, .params = words(np), .results = words(nr), .group = group, .doc = doc };
}

/// The qjs membrane's data table: one entry per `weft.qjs_*` import
/// quickjs.zig's three registration sites bind. Add or change an import
/// here, then bind its handler(s) in quickjs.zig (a `.config` entry needs
/// one real handler wired into `defineConfigFns`; a `.plugin` entry needs a
/// stub wired into `evalConfig` and a real handler wired into
/// `JsPlugin.load`) — the registration loops assert every entry got one.
pub const imports = [_]Entry{
    // ── the config plane: real handlers on every linker ─────────────────
    e("qjs_bind_key", 6, 0, .config, "weft.bind(scope, key, cmds): bind a key chord in scope `m` to a framed first-applicable intention list (doc/configuration.md §5.2)"),
    e("qjs_run", 4, 0, .config, "run a command by name with up to eight bounded string args (weft.run)"),
    e("qjs_echo", 2, 0, .config, "print a message to the echo area"),
    e("qjs_log", 2, 0, .config, "write a guest log line"),
    e("qjs_plugin", 2, 0, .config, "weft.plugin(name): stage a plugin load onto the manifest"),
    e("qjs_use", 2, 0, .config, "weft.use(name): evaluate `<config_dir>/<name>.js` into its own imported sub-manifest"),
    e("qjs_set", 6, 0, .config, "weft.set(plugin, key, blob): stage config data for a plugin, read at its init"),
    e("qjs_menu", 2, 0, .config, "weft.menu(name): declare a which-key style submenu mode"),
    e("qjs_action", 2, 0, .config, "weft.action(name): declare a pick action + its trampoline command"),
    e("qjs_semantic_action", 2, 0, .config, "weft.semanticAction(name): declare a focused-view action command"),
    e("qjs_provide", 9, 0, .config, "weft.provide(action, mode, lang, cmd, prio): register a provider"),
    e("qjs_status_segment", 5, 0, .config, "weft.statusSegment(text, role, priority): stage a static ui/statusline-seg segment onto the manifest (doc/cwa-prior-docs-audit.md §5)"),
    e("qjs_grant", 6, 0, .config, "weft.grant(plugin, capability, root): stage a GrantDecl onto the manifest — root (\"\" = unrestricted) narrows to Limit.fs_root (doc/contextual-workspace-architecture.md §13.5)"),
    e("qjs_viewport", 6, 0, .config, "weft.viewport(name, {edge, extent, cycles, persistent, followFocus}): stage a viewport's ATTRIBUTES onto the manifest — \"sidebar\" is a fragment setting these, not a kind (doc/cwa-config-decisions.md D1)"),
    e("qjs_present", 4, 0, .config, "weft.present(viewport, {subject}): stage \"show this subject in that viewport\" (doc/contextual-workspace-architecture.md §7)"),

    // ── the plugin plane: stubbed on the config linker, real on a JsPlugin's ─
    e("qjs_register", 2, 1, .plugin, "bind a command name to this JS plugin's on_command; returns its id"),
    // The four proc doors run `wasm_host/proc.zig`'s bodies — the SAME ones
    // `wl_proc_*` runs. Their arities are `wl_proc_*`'s by construction, not by
    // transcription (doc/place.md §4.1a).
    e("qjs_proc_spawn", 2, 1, .plugin, "spawn a persistent subprocess in the dispatching entry's place; returns a handle"),
    e("qjs_proc_send", 3, 0, .plugin, "write to a spawned subprocess's stdin"),
    e("qjs_proc_read", 3, 1, .plugin, "drain buffered stdout from a spawned subprocess"),
    e("qjs_proc_close", 1, 0, .plugin, "kill a spawned subprocess"),
    e("qjs_buffer_append", 5, 0, .plugin, "append text (+style class) to a named buffer, authored as the transcript peer"),
    e("qjs_buffer_fold", 4, 0, .plugin, "collapse `[start,end)` of a named buffer as an invisible/foldable span"),
    e("qjs_buffer_len", 2, 1, .plugin, "weft.bufferLen(name): a named buffer's byte length"),
    e("qjs_transcript_entry", 6, 0, .plugin, "weft.transcriptEntry(name, role, text): start a new entry in this plugin's live TranscriptDoc (created on first use), re-filling the named projected buffer (W6 check-in producer seam)"),
    e("qjs_transcript_append", 4, 0, .plugin, "weft.transcriptAppend(name, text): stream a chunk onto the currently-open entry's body as a text-CRDT insert, re-filling the named projected buffer"),
    e("qjs_config", 4, 1, .plugin, "weft.config(key): this plugin's staged config value"),
    e("qjs_breakpoints", 4, 1, .plugin, "weft.breakpoints(path): the file's breakpoint lines as a CSV"),
    e("qjs_file_read", 4, 1, .plugin, "weft.fileRead(path): the file's live-buffer-or-disk content for an agent read"),
    e("qjs_file_write", 6, 1, .plugin, "weft.fileWrite(path, content): replace the buffer for `path`, authored as the agent peer (0 ok, `denied` refused)"),
    e("qjs_line_text", 2, 1, .plugin, "weft.lineText(): the active buffer's current line"),
    e("qjs_active_buffer", 2, 1, .plugin, "weft.activeBuffer(): the focused buffer's display name — how an instanced JS tool routes a command to the session you can see"),
    e("qjs_pick", 6, 0, .plugin, "weft.pick(prompt, options, token): open a pick bound to this JS plugin; onPick receives the candidate/input/cancelled outcome carrying `token` back — the continuation identity that answers ONE request, never \"the pending one\""),
    e("qjs_status", 2, 0, .plugin, "weft.status(text): set the generic plugin status chip"),

    // ── the READ surface: the same bodies `wl_cursor`/`wl_slice`/… run ──
    // A JS plugin runs inside quickjs.wasm, which IS a wasm plugin, so it can
    // read the buffer it is in. It could not, until these: it had
    // `qjs_line_text` and nothing else, which is a narrower answer to a
    // question `line_at` + `slice` already answer. Arities are `wl_*`'s by
    // construction — one body each in `wasm_host/edit.zig`'s `read_doors`,
    // proven by function pointer in `e2e/demolition_test.zig`.
    e("qjs_cursor", 0, 1, .plugin, "weft.cursor(): the caret's byte offset in the entry this call is about"),
    e("qjs_byte_len", 0, 1, .plugin, "weft.byteLen(): that entry's length in bytes"),
    e("qjs_slice", 4, 1, .plugin, "weft.slice(start, end): its bytes in [start, end)"),
    e("qjs_line_at", 2, 0, .plugin, "weft.lineAt(offset): the [start, end) of the line containing `offset`"),
    e("qjs_selection", 1, 1, .plugin, "weft.selection(): the active selection's [start, end), or none"),
    e("qjs_path", 2, 1, .plugin, "weft.path(): the entry's backing file path, or none"),
    e("qjs_jump", 1, 0, .plugin, "weft.jump(offset): move the caret there"),
};

// ── Parity with the wasm plane ───────────────────────────────────────
// A JS plugin is code running inside `quickjs.wasm`, which IS a wasm plugin.
// It should therefore be able to do what a wasm plugin can — and the reason
// it cannot, today, is not a decision anybody made. It is that this table was
// hand-written door by door while `contract_data.zig` grew to 215, so the gap
// opened silently and nobody had to look at it.
//
// `parity` below makes the gap DATA. Every group of the wasm membrane is
// named here with the state of its JS twin, so:
//
//   - adding a wasm door to a `.shared` group and forgetting the JS side
//     fails the gate, not review;
//   - a group that is deliberately wasm-only has to SAY SO, in one line, in
//     a list a reader can scan;
//   - "what can a wasm plugin do that a JS plugin cannot" is a table you
//     read instead of a difference you discover.
//
// This is not the end state. The end state is that a `.js` plugin loads with
// the same surface a `.wasm` plugin does, because it is one; `.absent` rows
// are the work list for getting there, in the order they matter.
pub const Parity = enum {
    /// Both membranes run the SAME body (`wasm_host`'s), bound through
    /// `wasmDoor`/`jsDoor`. Proven by function pointer in
    /// `e2e/demolition_test.zig`, not by comment.
    shared,
    /// The JS plane has an equivalent under a different name and a different
    /// body, because the EFFECT legitimately differs.
    equivalent,
    /// The JS plane has no twin. Not a decision — a gap, with the reason it
    /// has not closed yet.
    absent,
};

pub const GroupParity = struct {
    group: @import("contract_data.zig").Group,
    state: Parity,
    /// For `.absent`, what it would take. For the others, what the twin is.
    note: []const u8,
};

pub const parity = [_]GroupParity{
    .{ .group = .proc, .state = .shared, .note = "the four proc doors: one body each in wasm_host/proc.zig, both planes generated from its `doors` table (doc/place.md §4.1a)" },
    .{ .group = .fs, .state = .equivalent, .note = "qjs_file_read/qjs_file_write share wasm_host/fs.zig's POLICY half (possession + .fs_root confinement) but author a buffer edit as the agent peer, where wl_fs_* touch the disk" },
    .{ .group = .commands, .state = .equivalent, .note = "qjs_register + qjs_run: two local id registries and two command trampolines, same command door underneath" },
    .{ .group = .config_kv, .state = .equivalent, .note = "qjs_config reads the same per-plugin config store wl_config does" },
    .{ .group = .keymap, .state = .equivalent, .note = "the .config group (qjs_bind_key/qjs_menu/qjs_action/…) is config's own role, not a lesser plugin surface" },
    .{ .group = .pick, .state = .equivalent, .note = "qjs_pick opens the same core picker; the outcome comes back through weft_on_pick carrying a continuation token instead of a pick id" },

    // The gap, in the order it costs a JS plugin something real.
    .{ .group = .edit, .state = .shared, .note = "the READ surface is shared: cursor/byte_len/slice/line_at/selection/path/jump run wasm_host/edit.zig's `read_doors` bodies on both planes. `wl_edit` itself is not — it authors as `p.principal()` and TRAPS on a doc-region violation, and a trap kills a resident QuickJS runtime the next command still needs, so sharing it means first deciding what a refused edit MEANS on a plane that cannot die" },
    .{ .group = .surface, .state = .absent, .note = "no retained overlay: acp.js and dap.js have a status chip and a buffer, and cannot paint the corner surface which_key and git use. Same shape as .edit — shared bodies plus C shim" },
    .{ .group = .slot, .state = .absent, .note = "a JS plugin can neither provide nor consume a typed capability, so it cannot participate in the D2 mesh at all — the biggest single second-classness left" },
    .{ .group = .intent, .state = .absent, .note = "cannot publish offers, so a JS-owned buffer answers no standard intention and its keys must all be bound by hand" },
    .{ .group = .semantic, .state = .absent, .note = "no target/view/field publication: a JS plugin cannot own a structured scene" },
    .{ .group = .buffers, .state = .absent, .note = "qjs_active_buffer answers the one question acp/dap needed (which instance is focused); the rest of the introspection surface has had no caller" },
    .{ .group = .declare, .state = .absent, .note = "no describe() handshake: a JS plugin declares nothing, so weft.grant is its ONLY authority door (config.js says so). Closing this means giving .js a describe phase" },
    .{ .group = .layers, .state = .absent, .note = "styles/folds/decorations on the active buffer; qjs_buffer_append/qjs_buffer_fold cover the narrow transcript case" },
    .{ .group = .annotate, .state = .absent, .note = "third-party decoration of an entry it does not own (§11.7)" },
    .{ .group = .dispatch, .state = .absent, .note = "mode/posture/resting declarations — a JS plugin owns no grammar today" },
    .{ .group = .menu, .state = .absent, .note = "menu/sticky-menu marks, which follow the keymap surface" },
    .{ .group = .capability, .state = .absent, .note = "the completion provider surface (wl_caps_*)" },
    .{ .group = .syntax, .state = .absent, .note = "tree-sitter reads: no caller yet" },
    .{ .group = .activation, .state = .absent, .note = "on_activate has no JS export twin" },
    .{ .group = .tool, .state = .absent, .note = "tool-backing declaration" },
    .{ .group = .register, .state = .absent, .note = "the shared kill/yank ring" },
    .{ .group = .sessions, .state = .absent, .note = "repl/net sessions; the JS plane has raw proc, which is the transport underneath them" },
};

/// Same drift-killing tripwire as contract_data.zig's `expected_import_count`
/// (see that file): bump this BY HAND alongside adding or removing a
/// `qjs_*` import, so a merge conflict or half-finished edit fails the
/// build instead of silently drifting quickjs.zig's three registration
/// sites apart.
const expected_count = 40;

comptime {
    // EVERY wasm import group must appear in `parity` exactly once. This is
    // the tripwire that makes the JS plane's gap a maintained decision: add a
    // group to `contract_data.Group` and the build stops until someone says
    // what it means for a `.js` plugin.
    @setEvalBranchQuota(20_000);
    const WasmGroup = @import("contract_data.zig").Group;
    for (std.enums.values(WasmGroup)) |g| {
        var seen = false;
        for (parity) |p| {
            if (p.group != g) continue;
            if (seen) @compileError("core/membrane/qjs_contract.zig: duplicate parity row for group '" ++ @tagName(g) ++ "'");
            seen = true;
            if (p.note.len == 0)
                @compileError("core/membrane/qjs_contract.zig: parity row for '" ++ @tagName(g) ++ "' needs a note — an unexplained gap is the thing this table exists to prevent");
        }
        if (!seen) @compileError(
            "core/membrane/qjs_contract.zig: wasm import group '" ++ @tagName(g) ++
                "' has no `parity` row. A JS plugin runs inside quickjs.wasm, which IS a wasm " ++
                "plugin — so every door the wasm plane grows is either given to the JS plane or " ++
                "written down as a gap with a reason. Add a row.",
        );
    }
}

comptime {
    @setEvalBranchQuota(10_000); // O(n²) duplicate scan, n=31
    if (imports.len != expected_count) @compileError(std.fmt.comptimePrint(
        "core/membrane/qjs_contract.zig: imports table has {d} entries, expected {d}. " ++
            "If you added or removed a qjs_* import, update `expected_count` here and wire " ++
            "its handler(s) in src/core/quickjs.zig (see this table's doc comment for which " ++
            "call sites a `.config` vs `.plugin` entry needs).",
        .{ imports.len, expected_count },
    ));
    for (imports, 0..) |a, i| {
        if (!std.mem.startsWith(u8, a.name, "qjs_"))
            @compileError("core/membrane/qjs_contract.zig: '" ++ a.name ++ "' doesn't look like a qjs_* import");
        if (a.params.len > 16)
            @compileError("core/membrane/qjs_contract.zig: '" ++ a.name ++ "' has more params than wasm.zig's trampoline can carry (16)");
        if (a.results.len > 8)
            @compileError("core/membrane/qjs_contract.zig: '" ++ a.name ++ "' has more results than wasm.zig's trampoline can carry (8)");
        for (imports[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name))
                @compileError("core/membrane/qjs_contract.zig: duplicate qjs_* import name '" ++ a.name ++ "'");
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────
const t = std.testing;

test "qjs membrane contract: every entry is well-formed, documented, and unique" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(t.allocator);
    var config_count: usize = 0;
    var plugin_count: usize = 0;
    for (imports) |entry| {
        try t.expect(std.mem.startsWith(u8, entry.name, "qjs_"));
        try t.expect(entry.doc.len > 0);
        try t.expect(entry.params.len <= 16 and entry.results.len <= 8);
        const gop = try seen.getOrPut(t.allocator, entry.name);
        try t.expect(!gop.found_existing);
        switch (entry.group) {
            .config => config_count += 1,
            .plugin => plugin_count += 1,
        }
    }
    try t.expectEqual(@as(usize, expected_count), imports.len);
    try t.expectEqual(@as(usize, 15), config_count); // defineConfigFns' surface
    try t.expectEqual(@as(usize, 25), plugin_count); // the resident-plugin-only surface
}

// Sealed eval (doc/configuration.md §5 C11; manifest.zig's module doc):
// the `.config` group is the ENTIRE channel a config script (or a
// `weft.use`-imported one) has to affect the world. This asserts, by
// inspecting the table rather than trusting a comment, that none of those
// ten imports is clock/env/random-shaped — the inventory manifest.zig's
// hash-determinism claim rests on. (`qjs_use`'s file read is confined to
// `<config_dir>/<name>.js`, not general fs — not name-shaped like a clock/
// env read, so not flagged here; see manifest.zig's doc for the one
// residual gap this table CAN'T see: QuickJS-ng's own built-in
// `Date`/`Math.random`.)
test "qjs membrane parity: every wasm group is claimed, and the gap is written down" {
    const WasmGroup = @import("contract_data.zig").Group;
    // Every group, exactly once — the comptime block proves this too; the
    // runtime copy is here so `zig build test` reports it as a named failure
    // rather than a build error nobody reads twice.
    for (std.enums.values(WasmGroup)) |g| {
        var found: usize = 0;
        for (parity) |p| {
            if (p.group == g) found += 1;
        }
        try t.expectEqual(@as(usize, 1), found);
    }
    // A `.shared` claim is a claim about BODIES, and `e2e/demolition_test.zig`
    // checks those by function pointer. What this asserts is that nobody
    // relabelled a gap as shared without one: today `proc` is the only group
    // that has earned it.
    var shared: usize = 0;
    for (parity) |p| {
        if (p.state == .shared) shared += 1;
    }
    try t.expectEqual(@as(usize, 2), shared);

    // And the honest headline: a JS plugin reaches 40 doors where a wasm
    // plugin reaches 215. Pinned so closing a gap is a visible, deliberate
    // number change rather than something that drifts either way.
    try t.expectEqual(@as(usize, 40), imports.len);
}

test "qjs membrane contract: no clock/env/random-shaped .config import" {
    const suspicious = [_][]const u8{ "time", "clock", "rand", "env", "getenv", "date", "now" };
    for (imports) |entry| {
        if (entry.group != .config) continue;
        for (suspicious) |bad| {
            try t.expect(std.mem.indexOf(u8, entry.name, bad) == null);
        }
    }
}
