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
        // shadowing another — the duplicate class (`open` and `buffer-close`
        // re-registered by the shell, `cursor-up` by main(), a grammar
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
        // bound arm is a registered command, an intention, or a menu mode.
        var modes = b.ed.keymap.modes.iterator();
        while (modes.next()) |mode| {
            var keys = mode.value_ptr.iterator();
            while (keys.next()) |key| for (key.value_ptr.commands) |arm| {
                if (core.catalog.isIntentionName(arm) or b.ed.keymap.modeHasTag(arm, "menu")) continue;
                if (std.mem.startsWith(u8, arm, "scroll.") or std.mem.eql(u8, arm, "grants.show")) continue; // the windowed shell's
                if (command_id.check(arm)) |why| {
                    std.debug.print("[e2e/identity] {s}: {s} {s} -> '{s}' {s}\n", .{ config, mode.key_ptr.*, key.key_ptr.*, arm, why.describe() });
                    return error.BoundIdOutsideGrammar;
                }
            };
        }
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
