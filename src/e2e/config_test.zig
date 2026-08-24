//! e2e test file — drives the shared harness (harness.zig) as a user and
//! observes the surface + disk. The alias block pulls what these tests need from
//! the one harness module; unused aliases are harmless at container scope.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const snail = h.snail;
const session = h.session;
const region = h.region;
const window_layout = h.window_layout;
const harness = h.gfx_harness;
const app_providers = h.app_providers;
const app_session = h.app_session;
const app_collab = h.app_collab;

const Editor = h.Editor;
const Loopback = h.Loopback;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;
const app_w = h.app_w;

const loadVim = h.loadVim;
const loadWorkspace = h.loadWorkspace;
const loadWebIde = h.loadWebIde;
const bootConfig = h.bootConfig;
const bootConfigNamed = h.bootConfigNamed;
const whichKeyText = h.whichKeyText;
const whichKeyShows = h.whichKeyShows;
const authorFile = h.authorFile;
const toolText = h.toolText;
const drainToolContains = h.drainToolContains;
const drainUntilOracle = h.drainUntilOracle;
const tmpPath = h.tmpPath;
const socketPair = h.socketPair;
const napUs = h.napUs;

// ── Driving the REAL config as a user (chords + which-key) ──────────
//
// Everything above hand-wired a plugin set; this boots the actual sample
// config.js and drives it the way a person does — through the SPC leader tree,
// discovering keys via which-key. The value is what this SURFACES: plugins the
// config references that don't load, keys that are bound weird, motions that
// don't do what a vim user expects.
test "e2e/config: the sample config boots; SPC g i is discoverable via which-key" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();

    // Boot the REAL config/config.js (read from the repo, which the Project
    // captured as prev_cwd before chdir'ing into the tmp project).
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);
    var loader_state: ConfigLoader = .{ .ed = &ed };
    defer loader_state.deinit();
    try bootConfig(&ed, config_dir, &loader_state);

    // Any plugin the sample config asked for but we couldn't load is a FINDING
    // — named on failure (only then, so a clean boot leaves stderr untouched).
    if (loader_state.missing.items.len > 0) {
        for (loader_state.missing.items) |nm| std.debug.print("[e2e/config] not in catalog: {s}\n", .{nm});
    }
    if (loader_state.failed.items.len > 0) {
        for (loader_state.failed.items) |nm| std.debug.print("[e2e/config] failed to load: {s}\n", .{nm});
    }
    try t.expect(loader_state.missing.items.len == 0);
    try t.expect(loader_state.failed.items.len == 0);

    // The config ran to completion (its last line echoes this).
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "config.js loaded") != null);

    // A user who forgets the git keys reaches for the leader and READS the
    // which-key overlay — so we assert on what the which_key plugin actually
    // renders to the surface, not on the keymap the harness could introspect.
    ed.press("SPC", "");
    try t.expectEqualStrings("space", ed.head.pending); // the chord is pending
    {
        const top = try whichKeyText(&ed, gpa);
        defer gpa.free(top);
        try t.expect(top.len > 0); // the overlay drew hints
        try t.expect(std.mem.indexOf(u8, top, "g") != null); // the git group key is shown
    }
    ed.press("g", ""); // drill into the git group
    try t.expectEqualStrings("space g", ed.head.pending);
    // The overlay now shows the git leaves BY THEIR COMMAND NAMES — what a user
    // reads to discover the binding we added.
    try t.expect(whichKeyShows(&ed, "git-init"));
    try t.expect(whichKeyShows(&ed, "git-status"));
    ed.press("Escape", ""); // abandon the chord; nothing ran
    try t.expectEqualStrings("", ed.head.pending);

    // Structured views use the same generic semantic action commands from
    // config: no dired-specific keymap or dispatch branch is needed.  The
    // names are visible through which-key, which also proves the config can
    // exercise focus, field, transfer, target, and view-lifecycle intents.
    ed.press("SPC", "");
    ed.press("v", "");
    try t.expectEqualStrings("space v", ed.head.pending);
    try t.expect(whichKeyShows(&ed, "cursor-down"));
    try t.expect(whichKeyShows(&ed, "field-edit"));
    try t.expect(whichKeyShows(&ed, "selection-copy"));
    try t.expect(whichKeyShows(&ed, "selection-cut"));
    try t.expect(whichKeyShows(&ed, "selection-delete"));
    try t.expect(whichKeyShows(&ed, "selection-paste-before"));
    try t.expect(whichKeyShows(&ed, "selection-paste-after"));
    try t.expect(whichKeyShows(&ed, "target-open-focused"));
    try t.expect(whichKeyShows(&ed, "view-refresh"));
    try t.expect(whichKeyShows(&ed, "view-revert"));
    try t.expect(whichKeyShows(&ed, "view-apply"));
    ed.press("Escape", "");

    // SPC : must open the command PALETTE (pick-commands), not the ex line.
    // Typing `:` needs Shift, and a real keyboard sends that Shift_L press as its
    // own event BETWEEN space and colon — it must not dead-end the chord.
    ed.press("SPC", "");
    try t.expectEqualStrings("space", ed.head.pending);
    ed.press("Shift_L", ""); // the modifier for `:` — a no-op for the chord
    try t.expectEqualStrings("space", ed.head.pending); // still pending, not reset
    ed.press(":", "");
    try t.expectEqualStrings("", ed.head.pending); // the chord resolved + ran
    try t.expect(ed.pick.active); // the palette (a pick), not the ex prompt
}

// ── M3/M4 parity: config.js vs config.northstar.js (north-star-plan §8) ──
//
// north-star-config.js is doc/north-star-config.js's forcing-function
// argument made real: today's editor, reproduced as a config that evaluates
// to a sealed MANIFEST (src/core/manifest.zig) instead of mutating the
// editor inline. Its only declared semantic edits vs config/config.js are
// (1) the which-key delay moving from the "editor" grab-bag to its owning
// plugin's namespace, and (2) trust-root framing in comments. This test is
// the M4 skeleton's keymap/action/value surface, asserted now: two headless
// editors, booted from the two files (same config/ dir, so both resolve
// `weft.use("defaults")` identically), must reach the same resolved keymap
// tables, the same action-provider resolutions, and the same which-key
// delay — under its NEW owner.
test "e2e/config: config.js and config.northstar.js reach the same manifest surface (M3/M4 parity)" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);

    var ed_a: Editor = undefined;
    try Editor.init(gpa, &ed_a);
    defer ed_a.deinit();
    var loader_a: ConfigLoader = .{ .ed = &ed_a };
    defer loader_a.deinit();
    try bootConfigNamed(&ed_a, config_dir, "config.js", &loader_a);

    var ed_b: Editor = undefined;
    try Editor.init(gpa, &ed_b);
    defer ed_b.deinit();
    var loader_b: ConfigLoader = .{ .ed = &ed_b };
    defer loader_b.deinit();
    try bootConfigNamed(&ed_b, config_dir, "config.northstar.js", &loader_b);

    if (loader_a.missing.items.len > 0) for (loader_a.missing.items) |nm| std.debug.print("[e2e/config parity] config.js: not in catalog: {s}\n", .{nm});
    if (loader_a.failed.items.len > 0) for (loader_a.failed.items) |nm| std.debug.print("[e2e/config parity] config.js: failed to load: {s}\n", .{nm});
    if (loader_b.missing.items.len > 0) for (loader_b.missing.items) |nm| std.debug.print("[e2e/config parity] config.northstar.js: not in catalog: {s}\n", .{nm});
    if (loader_b.failed.items.len > 0) for (loader_b.failed.items) |nm| std.debug.print("[e2e/config parity] config.northstar.js: failed to load: {s}\n", .{nm});
    try t.expect(loader_a.missing.items.len == 0);
    try t.expect(loader_a.failed.items.len == 0);
    try t.expect(loader_b.missing.items.len == 0);
    try t.expect(loader_b.failed.items.len == 0);

    // Both configs ran to completion.
    try t.expect(std.mem.indexOf(u8, ed_a.echoText(), "config.js loaded") != null);
    try t.expect(std.mem.indexOf(u8, ed_b.echoText(), "config.js loaded") != null);

    // 1. Resolved keymap tables, every mode — must match exactly (owner/
    //    priority excluded: reaching the same table through a different
    //    tier IS the point, not a difference to catch).
    const km_a = try h.keymapSnapshot(gpa, ed_a.keymap);
    defer gpa.free(km_a);
    const km_b = try h.keymapSnapshot(gpa, ed_b.keymap);
    defer gpa.free(km_b);
    try t.expectEqualStrings(km_a, km_b);

    // 2. Action provider sets — resolved outcomes across the modes/langs the
    //    configs actually declare providers for (`eval`: default, zig, py —
    //    "rs" exercises the unprovided-language DEFAULT fallthrough;
    //    `format`: default only, every lang) — must match exactly, plus
    //    explicit assertions naming what each SHOULD resolve to (not just
    //    "the two configs agree with each other", but "they agree on the
    //    RIGHT thing").
    const actions = [_][]const u8{ "eval", "format" };
    const modes = [_][]const u8{ "normal", "insert" };
    const langs = [_][]const u8{ "zig", "py", "rs" };
    const act_a = try h.actionSnapshot(gpa, ed_a.ctx, &actions, &modes, &langs);
    defer gpa.free(act_a);
    const act_b = try h.actionSnapshot(gpa, ed_b.ctx, &actions, &modes, &langs);
    defer gpa.free(act_b);
    try t.expectEqualStrings(act_a, act_b);

    inline for (.{ &ed_a, &ed_b }) |ed| {
        try t.expectEqualStrings("make-build", ed.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "zig" }).?);
        try t.expectEqualStrings("lang-run", ed.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "py" }).?);
        // "rs" has no provider of its own — the unconstrained default wins.
        try t.expectEqualStrings("run-line", ed.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "rs" }).?);
        try t.expectEqualStrings("format-buffer", ed.ctx.actions.resolve("format", .{ .mode = "normal", .lang = "zig" }).?);
        try t.expectEqualStrings("format-buffer", ed.ctx.actions.resolve("format", .{ .mode = "normal", .lang = "rs" }).?);
    }

    // 3. The which-key delay value — the ONE migrated key (§8's finding:
    //    "editor" grab-bag → the owning `which_key` plugin's namespace) —
    //    staged identically by both (raw framed blobs compare equal; "200"
    //    is legible in both as a sanity check the value itself is right).
    const raw_a = ed_a.config_kv.get("which_key", "delay-ms").?;
    const raw_b = ed_b.config_kv.get("which_key", "delay-ms").?;
    try t.expectEqualStrings(raw_a, raw_b);
    try t.expect(std.mem.indexOf(u8, raw_a, "200") != null);

    // 4. Theme values — a DIFFERENT config-value namespace than which_key's,
    //    exercising the "theme" core namespace side of the ownership check.
    inline for (.{ "accent", "cursor", "selection" }) |field| {
        const va = ed_a.config_kv.get("theme", field).?;
        const vb = ed_b.config_kv.get("theme", field).?;
        try t.expectEqualStrings(va, vb);
    }

    // 5. Plugin load-LIST set-equality — every `weft.plugin(name)` request,
    //    not just "no missing/failed" (which only checks the CATALOG side);
    //    this catches a name silently dropped or renamed between the two
    //    files.
    const req_a = try h.requestedPluginsSnapshot(gpa, &loader_a);
    defer gpa.free(req_a);
    const req_b = try h.requestedPluginsSnapshot(gpa, &loader_b);
    defer gpa.free(req_b);
    try t.expectEqualStrings(req_a, req_b);
    // config.js declares 38 `weft.plugin(...)` catalog entries (edit through
    // dap.js) — pin the count so a silently truncated list still fails
    // loudly even in the (impossible, given the equality above) case both
    // sides truncated identically.
    var req_count: usize = 0;
    for (req_a) |c| if (c == '\n') {
        req_count += 1;
    };
    try t.expectEqual(@as(usize, 38), req_count);

    // 6. The FULL config-store snapshot (namespace/key/value, every entry —
    //    not a hand-picked key), so e.g. `lsp/zig` agreeing is asserted too,
    //    not just `which_key/delay-ms` and `theme/*`.
    const kv_a = try h.kvSnapshot(gpa, &ed_a.config_kv);
    defer gpa.free(kv_a);
    const kv_b = try h.kvSnapshot(gpa, &ed_b.config_kv);
    defer gpa.free(kv_b);
    try t.expectEqualStrings(kv_a, kv_b);
    try t.expect(std.mem.indexOf(u8, kv_a, "lsp") != null); // the lsp/zig=zls entry is actually present

    // 7. Menu-mode / which-key GROUP structure (isMenuMode, sticky, locked,
    //    resting, text-swallow per mode) — not just individual binds; two
    //    configs could resolve the same bind table while disagreeing on
    //    which modes are which-key GROUPS vs runnable leaves.
    const ms_a = try h.modeStructureSnapshot(gpa, ed_a.keymap);
    defer gpa.free(ms_a);
    const ms_b = try h.modeStructureSnapshot(gpa, ed_b.keymap);
    defer gpa.free(ms_b);
    try t.expectEqualStrings(ms_a, ms_b);
}

// M3 review R1 regression, at the e2e layer (unit-level regression lives in
// quickjs.zig): the DOCUMENTED ACP setup — `weft.set("acp", "cmd", …)`
// before `weft.plugin("acp.js")` — must still land its value. `acp.js` is a
// path-form `.js` name; its config-store identity is the STEM ("acp"), not
// the raw declared name, and the value-ownership check (north-star-plan
// §2.4) must recognize that or a real, pre-M3-working config setup breaks
// silently (M4 parity item 6).
test "e2e/config: R1 — weft.set(\"acp\", ...) before weft.plugin(\"acp.js\") is not dropped" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    var loader_state: ConfigLoader = .{ .ed = &ed };
    defer loader_state.deinit();

    const dir = ".zig-cache/tmp/e2e-r1-acp";
    const cfg_path = dir ++ "/config.js";
    try core.file.writeBytesMakingDirs(gpa, dir, cfg_path,
        \\weft.set("acp", "cmd", "codex-acp");
        \\weft.plugin("acp.js");
    );
    defer core.file.deleteFile(gpa, cfg_path);

    try bootConfigNamed(&ed, dir, "config.js", &loader_state);

    const blob = ed.config_kv.get("acp", "cmd") orelse return error.ValueWronglyDropped;
    try t.expect(std.mem.indexOf(u8, blob, "codex-acp") != null);
}
