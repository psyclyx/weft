//! Command identity (doc/chrome.md §1): the gates that keep every command in
//! one id grammar, registered once, and presented to people — over what the
//! three shipped configs actually register, not over a list kept here.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const core = h.core;
const weft = @import("weft");

const Editor = h.Editor;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;
const command_id = core.membrane.wl.command_id;

/// One booted configuration: the editor, its loader, its project.
const Booted = struct {
    proj: Project = undefined,
    ed: Editor = undefined,
    loader: ConfigLoader = undefined,

    fn init(self: *Booted, gpa: std.mem.Allocator, config: []const u8) !void {
        try self.proj.init(gpa);
        errdefer self.proj.deinit();
        try Editor.init(gpa, &self.ed);
        errdefer self.ed.deinit();
        self.loader = .{ .ed = &self.ed };
        const dir = try std.fmt.allocPrint(gpa, "{s}/config", .{self.proj.prev_cwd});
        defer gpa.free(dir);
        try h.bootConfigNamed(&self.ed, dir, config, &self.loader);
        try t.expect(self.loader.missing.items.len == 0);
        try t.expect(self.loader.failed.items.len == 0);
        // What main() adds beside the config: the collaboration verbs.
        try self.ed.enableCollabCommands();
    }

    fn deinit(self: *Booted) void {
        self.loader.deinit();
        self.ed.deinit();
        self.proj.deinit();
    }
};

const configs = [_][]const u8{ "config.js", "helix.js", "ide.js" };

/// A summary is one sentence: a capital (or a digit) first, a full stop
/// last, no line breaks.
fn summaryStyled(s: []const u8) bool {
    if (s.len < 2) return false;
    if (!(std.ascii.isUpper(s[0]) or std.ascii.isDigit(s[0]))) return false;
    if (s[s.len - 1] != '.') return false;
    return std.mem.indexOfAny(u8, s, "\t\n") == null;
}

const menu_roots = [_][]const u8{ "File", "Edit", "Selection", "View", "Go", "Run", "Terminal", "Help" };

fn iconKnown(name: []const u8) bool {
    for (weft.gfx.icons.lucide) |icon| if (std.mem.eql(u8, icon.name, name)) return true;
    return false;
}

/// Everything wrong with one registered command, printed; the count returned.
fn audit(ed: *Editor, name: []const u8, cmd: core.command.Command) usize {
    var bad: usize = 0;
    if (command_id.check(name)) |why| {
        std.debug.print("[e2e/identity] '{s}' {s}\n", .{ name, why.describe() });
        bad += 1;
    }
    const shown = core.presentations.of(ed.ctx, name) orelse cmd.meta;
    if (!summaryStyled(cmd.summary)) {
        std.debug.print("[e2e/identity] '{s}': summary is not one capitalised sentence: '{s}'\n", .{ name, cmd.summary });
        bad += 1;
    }
    if (!shown.internal and shown.label.len == 0 and !command_id.isIntentionShaped(name)) {
        std.debug.print("[e2e/identity] '{s}': a command a person runs has no label\n", .{name});
        bad += 1;
    }
    if (std.mem.endsWith(u8, shown.label, "…") or std.mem.endsWith(u8, shown.label, "...")) {
        std.debug.print("[e2e/identity] '{s}': label '{s}' spells its own prompt mark (set `prompts`)\n", .{ name, shown.label });
        bad += 1;
    }
    if (shown.menu.len > 0) {
        const root = shown.menu[0 .. std.mem.indexOfScalar(u8, shown.menu, '/') orelse shown.menu.len];
        const known = for (menu_roots) |r| {
            if (std.mem.eql(u8, r, root)) break true;
        } else false;
        if (!known or shown.internal) {
            std.debug.print("[e2e/identity] '{s}': menu '{s}' is not under the conventional top level, or is internal\n", .{ name, shown.menu });
            bad += 1;
        }
    }
    if (shown.icon.len > 0 and !iconKnown(shown.icon)) {
        std.debug.print("[e2e/identity] '{s}': icon '{s}' is not in the bundled set\n", .{ name, shown.icon });
        bad += 1;
    }
    return bad;
}

test "e2e/identity: every command the shipped configs register is one id in the grammar, registered once, and presented" {
    const gpa = t.allocator;
    for (configs) |config| {
        var b: Booted = .{};
        try b.init(gpa, config);
        defer b.deinit();
        const commands = b.ed.commands;

        // ONE REGISTRATION PER ID. A second bind of a bound id is a command
        // shadowing another — the duplicate class (`file.open` and `buffer.close`
        // re-registered by the shell, `cursor.up` by main(), a grammar
        // re-registering a window verb). The registry counts them.
        if (commands.rebinds != 0) {
            std.debug.print("[e2e/identity] {s}: {d} id(s) registered twice, the first '{s}'\n", .{ config, commands.rebinds, commands.nameOf(commands.first_rebound.?) });
            return error.CommandRegisteredTwice;
        }

        var bad: usize = 0;
        var labelled: usize = 0;
        for (commands.map.keys(), commands.map.values()) |name, value| {
            const cmd = value orelse continue;
            bad += audit(&b.ed, name, cmd);
            if (cmd.meta.label.len > 0) labelled += 1;
        }
        if (bad != 0) {
            std.debug.print("[e2e/identity] {s}: {d} problem(s)\n", .{ config, bad });
            return error.CommandIdentity;
        }
        try t.expect(labelled > 100);

        // And every key names something that answers, in the grammar too: a
        // bound arm is a command (or action) REGISTERED here, a standard
        // intention in the vocabulary, a plugin intention, or a menu mode.
        // Well-formed is not enough — an id bound under a name it lost in a
        // rename is well-formed and runs nothing.
        var shell_ctx: h.app.scroll.ScrollCtx = .{ .view = undefined, .fb = undefined };
        var shell: core.command.Commands = .empty;
        defer shell.deinit(gpa);
        try h.app.scroll.registerCommands(gpa, &shell, &shell_ctx);
        var unanswered: usize = 0;
        var modes = b.ed.keymap.modes.iterator();
        while (modes.next()) |mode| {
            var keys = mode.value_ptr.iterator();
            while (keys.next()) |key| for (key.value_ptr.commands) |arm| {
                if (b.ed.keymap.modeHasTag(arm, "menu")) continue;
                if (command_id.check(arm)) |why| {
                    std.debug.print("[e2e/identity] {s}: {s} {s} -> '{s}' {s}\n", .{ config, mode.key_ptr.*, key.key_ptr.*, arm, why.describe() });
                    return error.BoundIdOutsideGrammar;
                }
                if (std.mem.startsWith(u8, arm, "std.")) {
                    if (core.intentions.find(arm) != null) continue;
                } else if (core.catalog.isIntentionName(arm)) {
                    continue; // a plugin's word, offered when its plugin says so
                } else if (commands.resolve(arm) != null or shell.resolve(arm) != null) {
                    continue;
                } else if (std.mem.eql(u8, arm, "grants.show")) {
                    continue; // the windowed shell's, over its live System
                }
                std.debug.print("[e2e/identity] {s}: {s} {s} -> '{s}' is registered by nothing\n", .{ config, mode.key_ptr.*, key.key_ptr.*, arm });
                unanswered += 1;
            };
        }
        if (unanswered != 0) return error.BoundIdUnregistered;
    }
}

test "e2e/identity: the windowed shell's own commands are in the grammar and presented" {
    // Registered by main() over the live view, so no headless boot has them;
    // bound here into a table of their own, never run.
    const gpa = t.allocator;
    var b: Booted = .{};
    try b.init(gpa, "config.js");
    defer b.deinit();
    var scroll_ctx: h.app.scroll.ScrollCtx = .{ .view = undefined, .fb = undefined };
    var table: core.command.Commands = .empty;
    defer table.deinit(gpa);
    try h.app.scroll.registerCommands(gpa, &table, &scroll_ctx);
    var bad: usize = 0;
    for (table.map.keys(), table.map.values()) |name, value| bad += audit(&b.ed, name, value.?);
    try t.expectEqual(@as(usize, 0), bad);
}

test "e2e/identity: the gate refuses what the old spellings were, and admits the new" {
    // The same function `weft.plugin` runs at a plugin's comptime, and the
    // runtime gate above: one grammar, three readers.
    try t.expect(command_id.check("buffer-next") != null);
    try t.expect(command_id.check("vim/n/motion.word-fwd") != null);
    try t.expect(command_id.check("motions.word-fwd") != null);
    try t.expect(command_id.check("snipe.repeat-rev") != null);
    try t.expect(command_id.check("buffer.next") == null);
    try t.expect(command_id.check("plugin.code.format") == null);
}

test "e2e/identity: presentation crosses every plane — a wasm table, a JS plugin's options, the config tier — and reads back through both" {
    const gpa = t.allocator;
    var b: Booted = .{};
    try b.init(gpa, "config.js");
    defer b.deinit();
    const ed = &b.ed;

    // A `.wasm` plugin's CommandEntry fields, through `wl_declare_command_meta`.
    const palette = core.presentations.of(ed.ctx, "palette.open").?;
    try t.expectEqualStrings("Command Palette", palette.label);
    try t.expectEqualStrings("View", palette.menu);
    try t.expectEqualStrings("command", palette.icon);
    try t.expect(palette.prompts and !palette.internal);
    var shown: [64]u8 = undefined;
    try t.expectEqualStrings("Command Palette…", palette.shown(&shown, "palette.open"));
    // Its summary comes from the command itself.
    try t.expectEqualStrings("Run a command, or act on what the focused context offers, by name.", palette.summary);

    // A resident JS plugin's `weft.command(name, fn, {…})`, through
    // `qjs_declare_command_meta` — the same body.
    const agent = core.presentations.of(ed.ctx, "agent.start").?;
    try t.expectEqualStrings("Start Agent", agent.label);
    try t.expectEqualStrings("Run/Agents", agent.menu);
    try t.expectEqualStrings("bot", agent.icon);

    // The config tier: semantic.js describes an open action name it declares.
    const create = core.presentations.of(ed.ctx, "fs.create-file").?;
    try t.expectEqualStrings("New File", create.label);
    try t.expectEqualStrings("file-plus", create.icon);

    // And a JS plugin READS it back — `weft.commandMeta` and `weft.keysFor`
    // are `wl_command_meta`/`wl_keys_for`'s bodies on its plane — and
    // declares its own through the options form.
    try ed.loadJs("probe",
        \\weft.command("probe.read", () => {
        \\  const m = weft.commandMeta("palette.open");
        \\  const keys = weft.keysFor("palette.open");
        \\  weft.echo([m.label, m.icon, m.prompts ? "prompts" : "", m.internal ? "internal" : "", keys.join(",")].join("|"));
        \\}, { summary: "Read how the palette presents itself.", arity: "whole", label: "Probe Palette", menu: "Help", order: 7, icon: "info", internal: false });
        \\weft.command("probe.plumbing", () => {}, { summary: "Nothing a person runs.", arity: "whole", internal: true });
    );
    const probe = core.presentations.of(ed.ctx, "probe.read").?;
    try t.expectEqualStrings("Probe Palette", probe.label);
    try t.expectEqualStrings("Help", probe.menu);
    try t.expectEqual(@as(?i32, 7), probe.order);
    try t.expectEqualStrings("info", probe.icon);
    try t.expect(core.presentations.of(ed.ctx, "probe.plumbing").?.internal);
    ed.run("probe.read");
    const echoed = ed.echoText();
    try t.expect(std.mem.startsWith(u8, echoed, "Command Palette|command|prompts||"));
    // The keys: config.js's `SPC :` and vim's `SPC SPC`, as a person reads them.
    try t.expect(std.mem.indexOf(u8, echoed, "SPC") != null);
}

test "e2e/identity: which key runs it depends on where you are — the grammar, and what the context offers" {
    const gpa = t.allocator;
    const keys_for = core.keys_for;

    // The same command, two grammars: each reports its OWN keys. (One
    // project at a time: a project is the process's directory while it lives.)
    {
        var vim: Booted = .{};
        try vim.init(gpa, "config.js");
        defer vim.deinit();
        const under_vim = try keys_for.keysFor(vim.ed.ctx, gpa, "files.find", keys_for.personMode(vim.ed.ctx));
        defer keys_for.free(gpa, under_vim);
        try t.expect(contains(under_vim, "space space"));
        try t.expect(!contains(under_vim, "C-p"));
    }
    var ide: Booted = .{};
    try ide.init(gpa, "ide.js");
    defer ide.deinit();
    try core.file.writeBytes(gpa, "a.txt", "alpha\n");
    ide.ed.runStr("file.open", "a.txt");
    ide.ed.typeText("x"); // an edit, so the history offer is armed
    const under_ide = try keys_for.keysFor(ide.ed.ctx, gpa, "files.find", keys_for.personMode(ide.ed.ctx));
    defer keys_for.free(gpa, under_ide);
    try t.expectEqual(@as(usize, 1), under_ide.len);
    try t.expectEqualStrings("C-p", under_ide[0]);

    // An intention arm: ide binds C-z to [std.history.undo, edit.undo]. In a
    // text entry holding an edit the history offer answers with `edit.undo`,
    // so C-z is its key.
    const in_text = try keys_for.keysFor(ide.ed.ctx, gpa, "edit.undo", keys_for.personMode(ide.ed.ctx));
    defer keys_for.free(gpa, in_text);
    try t.expect(contains(in_text, "C-z"));
    // In an entry that holds no text the offer is REFUSED (`no-text`): C-z
    // there means the intention — pressing it says why — and runs no undo, so
    // it is no longer a key for `edit.undo`, only for the intention.
    const listing = try ide.ed.buffers.createView(gpa, "files: .", "files");
    try ide.ed.buffers.switchTo(gpa, listing, ide.ed.head, ide.ed.keymap);
    const in_listing = try keys_for.keysFor(ide.ed.ctx, gpa, "edit.undo", keys_for.personMode(ide.ed.ctx));
    defer keys_for.free(gpa, in_listing);
    try t.expect(!contains(in_listing, "C-z"));
    const intention = try keys_for.keysFor(ide.ed.ctx, gpa, "std.history.undo", keys_for.personMode(ide.ed.ctx));
    defer keys_for.free(gpa, intention);
    try t.expect(contains(intention, "C-z"));
}

fn contains(keys: []const []u8, want: []const u8) bool {
    for (keys) |k| if (std.mem.eql(u8, k, want)) return true;
    return false;
}

/// Plumbing a key inside a chord may still run (doc/chrome.md §1.2): a
/// mode's leave, a digit of a count, the letter that names a register or a
/// macro's register. What the key does is choose, not act, and which-key
/// lists none of it.
fn plumbing(arm: []const u8) bool {
    if (std.mem.endsWith(u8, arm, "-cancel") or std.mem.startsWith(u8, arm, "vim.cancel-")) return true;
    for ([_][]const u8{ "vim.count-", "helix.count-", "vim.register-", "vim.macro-record-" }) |prefix| {
        if (std.mem.startsWith(u8, arm, prefix)) return true;
    }
    const play = "vim.macro-play-";
    return std.mem.startsWith(u8, arm, play) and arm.len == play.len + 1;
}

test "e2e/identity: a key pressed inside a chord or a menu is presented — only plumbing is internal" {
    const gpa = t.allocator;
    for (configs) |config| {
        var b: Booted = .{};
        try b.init(gpa, config);
        defer b.deinit();
        var bad: usize = 0;
        var modes = b.ed.keymap.modes.iterator();
        while (modes.next()) |mode| {
            const name = mode.key_ptr.*;
            // A transient paints its own menu (`plugin_sdk/transient.zig`),
            // each switch and action by the label its spec gives.
            if (std.mem.endsWith(u8, name, "-menu")) continue;
            const menu = b.ed.keymap.modeHasTag(name, "menu");
            var keys = mode.value_ptr.iterator();
            while (keys.next()) |key| {
                const chord = std.mem.indexOfScalar(u8, key.key_ptr.*, ' ') != null;
                if (!menu and !chord) continue;
                for (key.value_ptr.commands) |arm| {
                    const shown = core.presentations.of(b.ed.ctx, arm) orelse continue;
                    if (!shown.internal or plumbing(arm)) continue;
                    std.debug.print("[e2e/identity] {s}: {s} [{s}] runs '{s}', marked internal — which-key cannot show it\n", .{ config, name, key.key_ptr.*, arm });
                    bad += 1;
                }
            }
        }
        try t.expectEqual(@as(usize, 0), bad);
    }
}

test "e2e/identity: which-key reads the keys inside `d`, `d i`, `d a` and helix's `g` by their labels" {
    const gpa = t.allocator;
    {
        var b: Booted = .{};
        try b.init(gpa, "config.js");
        defer b.deinit();
        const ed = &b.ed;
        try core.file.writeBytes(gpa, "wk.txt", "one two\n");
        ed.runStr("file.open", "wk.txt");
        ed.press("d", "");
        try t.expect(h.whichKeyShows(ed, "Inner Object"));
        try t.expect(h.whichKeyShows(ed, "To End of Line"));
        ed.press("i", "");
        try t.expectEqualStrings("op-inner", ed.mode());
        try t.expect(h.whichKeyShows(ed, "Inner Word"));
        try t.expect(h.whichKeyShows(ed, "Inner Paragraph"));
        ed.press("Escape", "");
        ed.press("d", "");
        ed.press("a", "");
        try t.expect(h.whichKeyShows(ed, "A Paragraph"));
        ed.press("Escape", "");
    }
    var b: Booted = .{};
    try b.init(gpa, "helix.js");
    defer b.deinit();
    const ed = &b.ed;
    try core.file.writeBytes(gpa, "wk.txt", "one two\n");
    ed.runStr("file.open", "wk.txt");
    ed.press("g", "");
    try t.expect(h.whichKeyShows(ed, "Goto Line Below"));
    try t.expect(h.whichKeyShows(ed, "Goto Last Line"));
    ed.press("Escape", "");
}

test "e2e/identity: the recent-files keys open the picker; the text blob behind it is plumbing" {
    // `project.recent` answers with the list as text, for the dashboard and
    // the pickers to read; a person pressing SPC f r wants to choose a file.
    const gpa = t.allocator;
    const Key = struct { config: []const u8, mode: []const u8, key: []const u8 };
    const keys = [_]Key{
        .{ .config = "config.js", .mode = "normal", .key = "SPC f r" },
        .{ .config = "config.js", .mode = "normal", .key = "SPC p p" },
        .{ .config = "helix.js", .mode = "helix-normal", .key = "SPC O r" },
        .{ .config = "helix.js", .mode = "helix-normal", .key = "SPC l p" },
    };
    for (keys) |k| {
        var b: Booted = .{};
        try b.init(gpa, k.config);
        defer b.deinit();
        var key_buf: [64]u8 = undefined;
        const arms = b.ed.keymap.lookupArms(k.mode, core.Keymap.normalizeKey(&key_buf, k.key)) orelse return error.KeyUnbound;
        try t.expectEqualStrings("project.open-recent", arms[0]);
        try t.expect(core.presentations.of(b.ed.ctx, "project.recent").?.internal);
    }
}
