//! core/membrane/qjs_contract.zig — the `weft.*` membrane's THIRD surface
//! (doc/north-star-plan.md §2.5, task W0a-D extension 3): the `qjs_*` import
//! table `src/core/quickjs.zig` binds onto quickjs.wasm's Linker, today
//! hand-listed at THREE call sites (`defineConfigFns`'s 13 config-plane
//! imports, `evalConfig`'s 15 plugin-plane stubs, `JsPlugin.load`'s 15
//! plugin-plane real handlers) that must all agree on every name's arity.
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

/// Which linker(s) an entry is bound on. `.config` — the 13 `weft.*` calls
/// every config/plugin script can make (bind/run/echo/log/plugin/use/set/
/// menu/action/provide/statusSegment/grant) — real handlers always. `.plugin` — the 15 calls
/// only a RESIDENT JS plugin makes (register/proc/buffer/config/
/// breakpoints/fileRead/fileWrite/lineText/pick/status); stubbed on the
/// config-eval linker (present to satisfy quickjs.wasm's shared import
/// list, never actually called there), real on a plugin's linker.
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
    e("qjs_bind_key", 6, 0, .config, "bind a key chord in mode `m` to command `c` (config plane)"),
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
    e("qjs_status_segment", 5, 0, .config, "weft.statusSegment(text, role, priority): stage a static ui/statusline-seg segment onto the manifest (north-star-plan task #19)"),
    e("qjs_grant", 6, 0, .config, "weft.grant(plugin, capability, root): stage a GrantDecl onto the manifest — root (\"\" = unrestricted) narrows to Limit.fs_root (north-star-plan §6 W4 slice 4)"),

    // ── the plugin plane: stubbed on the config linker, real on a JsPlugin's ─
    e("qjs_register", 2, 1, .plugin, "bind a command name to this JS plugin's on_command; returns its id"),
    e("qjs_proc_spawn", 4, 1, .plugin, "spawn a persistent subprocess; returns a handle"),
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
    e("qjs_file_write", 6, 0, .plugin, "weft.fileWrite(path, content): replace the buffer for `path`, authored as the agent peer"),
    e("qjs_line_text", 2, 1, .plugin, "weft.lineText(): the active buffer's current line"),
    e("qjs_pick", 4, 0, .plugin, "weft.pick(prompt, options): open a pick bound to this JS plugin; onPick receives candidate/input/cancelled outcome"),
    e("qjs_status", 2, 0, .plugin, "weft.status(text): set the generic plugin status chip"),
};

/// Same drift-killing tripwire as contract_data.zig's `expected_import_count`
/// (see that file): bump this BY HAND alongside adding or removing a
/// `qjs_*` import, so a merge conflict or half-finished edit fails the
/// build instead of silently drifting quickjs.zig's three registration
/// sites apart.
const expected_count = 30;

comptime {
    @setEvalBranchQuota(10_000); // O(n²) duplicate scan, n=30
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
    try t.expectEqual(@as(usize, 13), config_count); // defineConfigFns' surface
    try t.expectEqual(@as(usize, 17), plugin_count); // the resident-plugin-only surface
}

// Sealed eval (north-star-plan §2.3/§4 C11; manifest.zig's module doc):
// the `.config` group is the ENTIRE channel a config script (or a
// `weft.use`-imported one) has to affect the world. This asserts, by
// inspecting the table rather than trusting a comment, that none of those
// ten imports is clock/env/random-shaped — the inventory manifest.zig's
// hash-determinism claim rests on. (`qjs_use`'s file read is confined to
// `<config_dir>/<name>.js`, not general fs — not name-shaped like a clock/
// env read, so not flagged here; see manifest.zig's doc for the one
// residual gap this table CAN'T see: QuickJS-ng's own built-in
// `Date`/`Math.random`.)
test "qjs membrane contract: no clock/env/random-shaped .config import" {
    const suspicious = [_][]const u8{ "time", "clock", "rand", "env", "getenv", "date", "now" };
    for (imports) |entry| {
        if (entry.group != .config) continue;
        for (suspicious) |bad| {
            try t.expect(std.mem.indexOf(u8, entry.name, bad) == null);
        }
    }
}
