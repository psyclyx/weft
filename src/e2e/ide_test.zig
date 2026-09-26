//! e2e test file — config/ide.js and the `ide` grammar (doc/configs.md §3.2,
//! §3.8 step 1). ide.js binds one flat key per operation and asks it to mean
//! the right thing wherever the focus is, so these gates hold three claims:
//!
//!   • the config boots whole — every plugin it names loads, every key it or
//!     its grammar binds is answerable, and the sidebar is docked at startup;
//!   • the grammar edits the way a conventional editor does, keyboard only —
//!     typing, shift-selection that typing replaces, Tab over a selection,
//!     C-/, A-Down, each one undo unit;
//!   • ONE key resolves to a different provider per context — a text buffer,
//!     the files sidebar, a git status buffer — asked through the same
//!     `explain` paths which-key and `explain-binding` answer from, with no
//!     sidebar- or git-specific code in the grammar.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const window_layout = h.window_layout;
const Editor = h.Editor;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;

/// A weft booted from the real config/ide.js in a throwaway project that is
/// the process cwd — the ide.js twin of `h.App`.
const IdeApp = struct {
    proj: Project = undefined,
    ed: Editor = undefined,
    loader: ConfigLoader = undefined,

    fn init(self: *IdeApp, gpa: std.mem.Allocator) !void {
        try self.proj.init(gpa);
        errdefer self.proj.deinit();
        try Editor.init(gpa, &self.ed);
        errdefer self.ed.deinit();
        self.loader = .{ .ed = &self.ed };
        errdefer self.loader.deinit();
        const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{self.proj.prev_cwd});
        defer gpa.free(config_dir);
        try h.bootConfigNamed(&self.ed, config_dir, "ide.js", &self.loader);
        // Mirror main.zig: the grammar's own mode is where a fresh buffer rests.
        try self.ed.buffers.setDefaultMode(gpa, self.ed.head.currentMode());
    }

    fn deinit(self: *IdeApp) void {
        self.loader.deinit();
        self.ed.deinit();
        self.proj.deinit();
    }
};

/// Commands only a WINDOWED embedder registers (config_test.zig's list): a
/// headless editor has no live System or scrolling view to own them.
fn embedderOwned(command: []const u8) bool {
    return std.mem.eql(u8, command, "grants-show") or
        std.mem.eql(u8, command, "center-line") or
        std.mem.startsWith(u8, command, "scroll-");
}

fn textEd(ed: *Editor) *core.Editor {
    return ed.buffers.active().textEditor().?;
}

fn expectText(ed: *Editor, want: []const u8) !void {
    const got = try ed.textAlloc();
    defer ed.gpa.free(got);
    try t.expectEqualStrings(want, got);
}

fn cursor(ed: *Editor) usize {
    return textEd(ed).cursorOffset();
}

/// The selection as plain offsets, or null when there is none.
const Span = struct { start: usize, end: usize };
fn selected(ed: *Editor) ?Span {
    const r = textEd(ed).selectedRange() orelse return null;
    return .{ .start = r.start, .end = r.end };
}

/// Open `name` holding `body` as the focused text entry.
fn openFile(ed: *Editor, name: []const u8, body: []const u8) !void {
    try core.file.writeBytes(ed.gpa, name, body);
    ed.runStr("open", name);
    try t.expectEqualStrings("ide", ed.mode());
}

/// What `key` would do in the current mode, asked the way which-key asks.
fn explainKey(ed: *Editor, key: []const u8) core.intent.Explanation {
    var buf: [64]u8 = undefined;
    const spec = core.Keymap.normalizeKey(&buf, key);
    const arms = ed.keymap.lookupArms(ed.mode(), spec) orelse return .none;
    return core.intent.explain(ed.ctx, arms);
}

fn expectReady(ed: *Editor, key: []const u8, intention: []const u8, provider: []const u8) !void {
    switch (explainKey(ed, key)) {
        .ready => |r| {
            try t.expectEqualStrings(intention, r.intention);
            try t.expectEqualStrings(provider, r.provider);
        },
        else => |other| {
            std.debug.print("[e2e/ide] {s} in {s}: {s}, expected {s} via {s}\n", .{ key, ed.mode(), @tagName(other), intention, provider });
            return error.TestExpectedReady;
        },
    }
}

/// The key's intentions all fall through here, and the plain command arm it
/// names is what dispatch runs.
fn expectCommand(ed: *Editor, key: []const u8, command: []const u8) !void {
    try t.expect(explainKey(ed, key) == .none);
    var buf: [64]u8 = undefined;
    const spec = core.Keymap.normalizeKey(&buf, key);
    const arms = ed.keymap.lookupArms(ed.mode(), spec).?;
    try t.expectEqualStrings(command, arms[arms.len - 1]);
}

/// The provider `explain-binding <action>` names for the focused context.
fn expectActionWinner(ed: *Editor, action: []const u8, winner: []const u8) !void {
    ed.runStr("explain-binding", action);
    var want: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&want, "winner={s} ", .{winner});
    if (std.mem.indexOf(u8, ed.echoText(), needle) == null) {
        std.debug.print("[e2e/ide] explain-binding {s}: '{s}', expected winner {s}\n", .{ action, ed.echoText(), winner });
        return error.TestUnexpectedResult;
    }
}

test "e2e/ide: ide.js boots whole, every bound key is answerable, and the sidebar is docked" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    for (app.loader.missing.items) |nm| std.debug.print("[e2e/ide] not in the bundle: {s}\n", .{nm});
    for (app.loader.failed.items) |nm| std.debug.print("[e2e/ide] failed to load: {s}\n", .{nm});
    try t.expectEqual(@as(usize, 0), app.loader.missing.items.len);
    try t.expectEqual(@as(usize, 0), app.loader.failed.items.len);
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "ide.js loaded") != null);
    try t.expectEqualStrings("ide", ed.mode());
    // No vim: the modal grammar is not what answers these keys.
    try t.expect(ed.keymap.commitCommand("insert") == null);

    // Every arm of every key the config and its plugins bind resolves the way
    // `intent.zig` decides — an intention (the focus answers it), a menu mode,
    // or a registered command. Anything else is a dead key.
    var modes = ed.keymap.modes.iterator();
    while (modes.next()) |mode| {
        var keys = mode.value_ptr.iterator();
        while (keys.next()) |key| {
            for (key.value_ptr.commands) |arm| {
                if (core.catalog.isIntentionName(arm) or ed.keymap.modeHasTag(arm, "menu")) continue;
                if (embedderOwned(arm)) continue;
                if (ed.commands.resolve(arm) == null) {
                    std.debug.print("[e2e/ide] bound but unanswerable: {s} {s} -> {s}\n", .{ mode.key_ptr.*, key.key_ptr.*, arm });
                    return error.BoundCommandMissing;
                }
            }
        }
    }

    // The sidebar is open from the first frame: the fragment's declaration,
    // realized by the ordinary layout phase, with the editor still focused.
    const editor_entry = ed.buffers.active_id;
    ed.applyWindow();
    try t.expectEqual(@as(usize, 2), ed.paneCount());
    const panel = ed.win_layout.dockedPanel(.left) orelse return error.NoSidebar;
    const primary = ed.win_layout.primaryPane() orelse return error.NoPrimaryPane;
    const listing = ed.buffers.get(panel.pane().buffer_id) orelse return error.NoSidebarEntry;
    try t.expect(std.mem.startsWith(u8, listing.name, "files:"));
    try t.expectEqual(primary, window_layout.headFocus(ed.win_layout, ed.head));
    try t.expectEqual(editor_entry, ed.buffers.active_id);

    // C-b hides it and shows it again through core's generic viewport door —
    // no command anywhere knows the word "sidebar" but the config's value.
    ed.press("C-b", "");
    ed.applyWindow();
    try t.expectEqual(@as(usize, 1), ed.paneCount());
    try t.expect(ed.win_layout.dockedPanel(.left) == null);
    ed.press("C-b", "");
    ed.applyWindow();
    try t.expectEqual(@as(usize, 2), ed.paneCount());
    const again = ed.win_layout.dockedPanel(.left) orelse return error.NoSidebar;
    const shown = ed.buffers.get(again.pane().buffer_id) orelse return error.NoSidebarEntry;
    try t.expect(std.mem.startsWith(u8, shown.name, "files:"));
    try t.expectEqual(editor_entry, ed.buffers.active_id);
}

test "e2e/ide: the grammar edits like a conventional editor, one undo unit per operation" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "a.txt", "one\ntwo\nthree\n");

    // Typing self-inserts, and C-z takes the whole run back.
    ed.typeText("hi ");
    try expectText(ed, "hi one\ntwo\nthree\n");
    ed.press("C-z", "");
    try expectText(ed, "one\ntwo\nthree\n");

    // Shift extends from where it started; typing replaces what is selected.
    ed.press("C-Home", "");
    ed.chord("S-Right S-Right S-Right");
    try t.expectEqual(Span{ .start = 0, .end = 3 }, selected(ed).?);
    ed.typeText("1");
    try expectText(ed, "1\ntwo\nthree\n");
    try t.expect(selected(ed) == null);

    // A plain move collapses the selection to its near edge.
    ed.press("C-Home", "");
    ed.chord("S-End");
    try t.expectEqual(Span{ .start = 0, .end = 1 }, selected(ed).?);
    ed.press("Left", "");
    try t.expect(selected(ed) == null);
    try t.expectEqual(@as(usize, 0), cursor(ed));
    // …and Escape just drops it.
    ed.chord("S-Down");
    try t.expect(selected(ed) != null);
    ed.press("Escape", "");
    try t.expect(selected(ed) == null);

    // Tab indents every selected line (the line the selection ENDS at column
    // 0 of is not one of them) and keeps them selected; S-Tab undoes it; the
    // indent is one undo unit.
    ed.press("C-Home", "");
    ed.chord("S-Down S-Down");
    ed.press("Tab", "\t");
    try expectText(ed, "  1\n  two\nthree\n");
    try t.expect(selected(ed) != null);
    ed.press("ISO_Left_Tab", "");
    try expectText(ed, "1\ntwo\nthree\n");
    ed.press("Tab", "\t");
    try expectText(ed, "  1\n  two\nthree\n");
    ed.press("C-z", "");
    try expectText(ed, "1\ntwo\nthree\n");

    // Smart Home: first non-blank, then the margin.
    ed.press("Escape", "");
    try openFile(ed, "b.txt", "    indented\n");
    ed.press("End", "");
    ed.press("Home", "");
    try t.expectEqual(@as(usize, 4), cursor(ed));
    ed.press("Home", "");
    try t.expectEqual(@as(usize, 0), cursor(ed));

    // C-/ toggles the line's comment through the comment plugin.
    try openFile(ed, "c.txt", "alpha\nbeta\n");
    ed.press("C-/", "");
    try expectText(ed, "// alpha\nbeta\n");
    ed.press("C-/", "");
    try expectText(ed, "alpha\nbeta\n");

    // A-Down swaps the line with the next and the cursor rides along; the
    // swap is ONE edit, so one C-z restores it.
    ed.press("C-Home", "");
    ed.press("Right", "");
    ed.press("M-Down", "");
    try expectText(ed, "beta\nalpha\n");
    try t.expectEqual(@as(usize, 6), cursor(ed));
    ed.press("M-Up", "");
    try expectText(ed, "alpha\nbeta\n");
    ed.press("M-Down", "");
    ed.press("C-z", "");
    try expectText(ed, "alpha\nbeta\n");

    // C-c with nothing selected takes the line, C-v puts it above.
    ed.press("C-Home", "");
    ed.press("C-c", "");
    ed.press("Down", "");
    ed.press("C-v", "");
    try expectText(ed, "alpha\nalpha\nbeta\n");
    // C-x on a selection cuts it; C-v at the end brings it back.
    ed.press("C-Home", "");
    ed.chord("S-End");
    ed.press("C-x", "");
    try expectText(ed, "\nalpha\nbeta\n");
    ed.press("C-End", "");
    ed.press("C-v", "");
    try expectText(ed, "\nalpha\nbeta\nalpha");
}

test "e2e/ide: one key, three contexts — text, the files sidebar, and git resolve their own providers" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    for ([_][]const u8{
        "git init -q -b main",
        "git config user.email e2e@weft.test",
        "git config user.name weft-e2e",
        "printf 'one\\n' > f.txt && git add f.txt && git commit -q -m base",
        "printf 'two\\n' >> f.txt",
    }) |cmd| {
        const out = try app.proj.oracle(cmd);
        gpa.free(out);
    }
    try openFile(ed, "f.txt", "one\ntwo\n");
    ed.applyWindow();

    // ── A text buffer: the editing floor and the grammar's text arms. ──
    // Return has nothing to activate, so the line break core offers wins.
    try expectReady(ed, "Return", "std.editing.insert-line-break", "core.editing");
    // No row to transfer: the copy/cut/paste words fall to the text commands.
    try expectCommand(ed, "C-c", "ide-copy");
    try expectCommand(ed, "C-x", "ide-cut");
    try expectCommand(ed, "C-v", "ide-paste");
    try expectCommand(ed, "Down", "ide-down");
    try expectReady(ed, "C-z", "std.history.undo", "core.editing");
    try expectReady(ed, "C-s", "std.persistence.save", "core.editing");
    // F2 is an ACTION: in source it is the language server's rename.
    try expectActionWinner(ed, "rename-here", "rename");

    // ── The files sidebar: the same keys, answered by the listing. ──
    ed.run("window-focus-left");
    ed.applyWindow();
    const panel = ed.win_layout.dockedPanel(.left) orelse return error.NoSidebar;
    try t.expectEqual(panel.pane().buffer_id, ed.buffers.active_id);
    // It rests in the grammar's structural state, where no key is text.
    try t.expectEqualStrings("ide-structural", ed.mode());
    try t.expect(ed.keymap.commitCommand(ed.mode()) == null);
    // A keystroke first, as in production: Down is the same key as in text,
    // and here it steps a row.
    ed.press("Down", "");
    try expectReady(ed, "Down", "std.navigation.down", "core.view");
    try expectReady(ed, "Return", "std.target.activate", "core.view");
    try expectReady(ed, "C-c", "std.transfer.yank", "core.view");
    try expectReady(ed, "C-x", "std.transfer.delete-to-register", "core.view");
    try expectReady(ed, "C-v", "std.transfer.paste", "core.view");
    // …and F2 renames the ROW, through the provider keyed to this state.
    try expectActionWinner(ed, "rename-here", "field-edit");

    // ── A git status buffer: git's own mode, and the global layer. ──
    ed.run("window-focus-right");
    ed.applyWindow();
    ed.run("git-status");
    try t.expect(h.drainToolContains(ed, "*git*", "f.txt"));
    try t.expectEqualStrings("git", ed.mode());
    {
        const text = try ed.textAlloc();
        defer gpa.free(text);
        const at = std.mem.indexOf(u8, text, "f.txt") orelse return error.NoFileRow;
        const row = std.mem.count(u8, text[0..at], "\n");
        for (0..row) |_| ed.press("Down", "");
    }
    // Return is git's: the row opens its diff, attributed to git.
    try expectReady(ed, "Return", "plugin.git.open-diff", "plugin.git");
    // C-s reaches this tool mode, which falls back to nothing, only through
    // the global layer — and the persistence word resolves here as in text:
    // core's offer runs the `save` ACTION, whose providers decide per tool
    // (a commit draft commits) rather than this key.
    try t.expect(ed.keymap.lookupArms("git", "C-s") != null);
    try expectReady(ed, "C-s", "std.persistence.save", "core.editing");
}
