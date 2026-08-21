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
    try t.expectEqualStrings("space", ed.keymap.pending); // the chord is pending
    {
        const top = try whichKeyText(&ed, gpa);
        defer gpa.free(top);
        try t.expect(top.len > 0); // the overlay drew hints
        try t.expect(std.mem.indexOf(u8, top, "g") != null); // the git group key is shown
    }
    ed.press("g", ""); // drill into the git group
    try t.expectEqualStrings("space g", ed.keymap.pending);
    // The overlay now shows the git leaves BY THEIR COMMAND NAMES — what a user
    // reads to discover the binding we added.
    try t.expect(whichKeyShows(&ed, "git-init"));
    try t.expect(whichKeyShows(&ed, "git-status"));
    ed.press("Escape", ""); // abandon the chord; nothing ran
    try t.expectEqualStrings("", ed.keymap.pending);

    // SPC : must open the command PALETTE (pick-commands), not the ex line.
    // Typing `:` needs Shift, and a real keyboard sends that Shift_L press as its
    // own event BETWEEN space and colon — it must not dead-end the chord.
    ed.press("SPC", "");
    try t.expectEqualStrings("space", ed.keymap.pending);
    ed.press("Shift_L", ""); // the modifier for `:` — a no-op for the chord
    try t.expectEqualStrings("space", ed.keymap.pending); // still pending, not reset
    ed.press(":", "");
    try t.expectEqualStrings("", ed.keymap.pending); // the chord resolved + ran
    try t.expect(ed.pick.active); // the palette (a pick), not the ex prompt
}
