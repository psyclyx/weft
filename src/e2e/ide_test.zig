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
//!     `explain` paths which-key and `action.explain` answer from, with no
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
pub const IdeApp = struct {
    proj: Project = undefined,
    ed: Editor = undefined,
    loader: ConfigLoader = undefined,

    pub fn init(self: *IdeApp, gpa: std.mem.Allocator) !void {
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

    pub fn deinit(self: *IdeApp) void {
        self.loader.deinit();
        self.ed.deinit();
        self.proj.deinit();
    }
};

/// Commands only a WINDOWED embedder registers (config_test.zig's list): a
/// headless editor has no live System or scrolling view to own them.
fn embedderOwned(command: []const u8) bool {
    return std.mem.eql(u8, command, "grants.show") or
        std.mem.startsWith(u8, command, "scroll.");
}

pub fn textEd(ed: *Editor) *core.Editor {
    return ed.buffers.active().textEditor().?;
}

pub fn expectText(ed: *Editor, want: []const u8) !void {
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
pub fn openFile(ed: *Editor, name: []const u8, body: []const u8) !void {
    try core.file.writeBytes(ed.gpa, name, body);
    ed.runStr("file.open", name);
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

/// The key's arm is RELEVANT here but refuses, with `reason` — which is what
/// which-key shows and what the keypress reports instead of running a later
/// arm.
fn expectBlocked(ed: *Editor, key: []const u8, intention: []const u8, reason: []const u8) !void {
    switch (explainKey(ed, key)) {
        .blocked => |b| {
            try t.expectEqualStrings(intention, b.intention);
            try t.expectEqualStrings(reason, b.reason);
        },
        else => |other| {
            std.debug.print("[e2e/ide] {s} in {s}: {s}, expected {s} blocked by {s}\n", .{ key, ed.mode(), @tagName(other), intention, reason });
            return error.TestExpectedBlocked;
        },
    }
}

/// Whether anything offers `intention` in the active context at all —
/// absence (nonapplicable), as distinct from a disabled offer.
pub fn offered(ed: *Editor, intention: []const u8) bool {
    const plane = ed.ctx.intent orelse return false;
    const id = plane.catalog.findIntention(intention) orelse return false;
    const snap = plane.snapshotFor(ed.ctx) orelse return false;
    return snap.offersFor(id).len > 0;
}

/// Run a command and read its integer result (the fixture's counters).
fn runInt(ed: *Editor, cmd: []const u8, args: []const core.command.Value) i64 {
    const v = core.command.run(ed.commands, ed.ctx, cmd, args) catch return -1;
    return if (v == .integer) v.integer else -1;
}

/// Run a command and copy its string result (the fixture's listings).
fn runStr(ed: *Editor, buf: []u8, cmd: []const u8, args: []const core.command.Value) []const u8 {
    const v = core.command.run(ed.commands, ed.ctx, cmd, args) catch return "";
    const s = switch (v) {
        .string => |s| s,
        else => return "",
    };
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
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

/// The provider `action.explain <action>` names for the focused context.
fn expectActionWinner(ed: *Editor, action: []const u8, winner: []const u8) !void {
    ed.runStr("action.explain", action);
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
    // Five panes: the editor, the sidebar, the menubar and the toolbar along
    // the top, and the status bar along the bottom.
    const editor_entry = ed.buffers.active_id;
    ed.applyWindow();
    try t.expectEqual(@as(usize, 5), ed.paneCount());
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
    try t.expectEqual(@as(usize, 4), ed.paneCount());
    try t.expect(ed.win_layout.dockedPanel(.left) == null);
    ed.press("C-b", "");
    ed.applyWindow();
    try t.expectEqual(@as(usize, 5), ed.paneCount());
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
    // No row to transfer: the copy/cut/paste words are core's over text,
    // offered because the grammar provides what they mean here — so they
    // run ide's own text arms, and a context menu can list them.
    try expectReady(ed, "C-c", "std.transfer.yank", "core.editing");
    try expectReady(ed, "C-x", "std.transfer.delete-to-register", "core.editing");
    try expectReady(ed, "C-v", "std.transfer.paste", "core.editing");
    try expectCommand(ed, "Down", "ide.down");
    // REAL availability: a buffer nothing has changed has nothing to undo, so
    // the offer is there but DISABLED, with the reason which-key shows — and
    // it becomes ready the moment there is an edit to take back.
    try expectBlocked(ed, "C-z", "std.history.undo", "nothing-to-undo");
    try expectBlocked(ed, "C-S-z", "std.history.redo", "nothing-to-redo");
    ed.press("End", "");
    ed.typeText("!");
    try expectReady(ed, "C-z", "std.history.undo", "core.editing");
    ed.press("C-z", "");
    try expectText(ed, "one\ntwo\n");
    try expectReady(ed, "C-S-z", "std.history.redo", "core.editing");
    try expectReady(ed, "C-s", "std.persistence.save", "core.editing");
    // F2 is an ACTION: in source it is the language server's rename.
    try expectActionWinner(ed, "plugin.code.rename", "rename");

    // ── The files sidebar: the same keys, answered by the listing. ──
    ed.run("window.focus-left");
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
    // …and F2 renames the ROW, through the config provider keyed on this
    // entry's tool identity (a `weft.provide` fact beyond mode and lang).
    try expectActionWinner(ed, "plugin.code.rename", "field.edit");
    // Whether the persistence word applies is the `save` providers' call, not
    // core's: the files listing provides one (it applies the draft), so C-s
    // is offered here and runs THAT — while a git listing, below, provides
    // none and is not offered it at all.
    try expectReady(ed, "C-s", "std.persistence.save", "core.editing");
    try expectActionWinner(ed, "file.save", "view.apply");

    // ── A git status buffer: git's own mode, and the global layer. ──
    ed.run("window.focus-right");
    ed.applyWindow();
    ed.run("git.status");
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
    // the global layer. A status listing has nothing durable: no `save`
    // provider is eligible for a tool projection that did not provide one (a
    // commit draft does, and commits), so core does not offer the persistence
    // word here and the key falls through to its plain `save` arm — which
    // refuses for want of a provider instead of "saving" a listing.
    try t.expect(ed.keymap.lookupArms("git", "C-s") != null);
    try t.expect(!offered(ed, "std.persistence.save"));
    try expectCommand(ed, "C-s", "file.save");
    // F2's config providers: git's rows are not the files tool, and a status
    // listing is not text, so neither answers — the same action, a third
    // answer: not offered here at all (so no toolbar shows it either).
    try t.expect(!offered(ed, "plugin.code.rename"));
}

test "e2e/ide: a toolbar's doors describe the editor while a sidebar holds focus, and say when that changes" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try h.loadOfferwatch(ed);
    try openFile(ed, "a.txt", "one\n");
    const editor_entry = ed.buffers.active_id;
    var buf: [1 << 14]u8 = undefined;

    // The first wake delivers the first description; quiet wakes deliver
    // nothing — no polling, and no event without a change.
    ed.applyWindow();
    const first = runInt(ed, "offerwatch.fired", &.{});
    try t.expect(first >= 1);
    ed.applyWindow();
    ed.applyWindow();
    try t.expectEqual(first, runInt(ed, "offerwatch.fired", &.{}));
    // A caret move changes nothing a toolbar shows.
    ed.press("End", "");
    ed.applyWindow();
    try t.expectEqual(first, runInt(ed, "offerwatch.fired", &.{}));
    // An edit does — Undo becomes available — and it is ONE event however
    // many wakes follow.
    ed.typeText("!");
    ed.applyWindow();
    ed.applyWindow();
    try t.expectEqual(first + 1, runInt(ed, "offerwatch.fired", &.{}));
    // …and it names exactly what moved: the offers, not the entry or mode.
    try t.expectEqualStrings("offers", runStr(ed, &buf, "offerwatch.keys", &.{}));

    // Focus the docked sidebar. The PRIMARY context is still the editor, so
    // what a toolbar describes did not move: no event.
    ed.run("window.focus-left");
    ed.applyWindow();
    try t.expect(ed.buffers.active_id != editor_entry);
    ed.press("Down", ""); // onto a row, as a user would
    ed.applyWindow();
    try t.expectEqual(first + 1, runInt(ed, "offerwatch.fired", &.{}));

    // The primary enumeration is the EDITOR's — its history and persistence
    // words, presented with the intention table's labels and groups — while
    // the active one is the listing's.
    const primary = runStr(ed, &buf, "offerwatch.list", &.{.{ .integer = 1 }});
    try t.expect(std.mem.indexOf(u8, primary, "std.history.undo|core.editing|enabled||Undo|history|") != null);
    try t.expect(std.mem.indexOf(u8, primary, "std.history.redo|core.editing|disabled|nothing-to-redo|Redo|history|") != null);
    try t.expect(std.mem.indexOf(u8, primary, "std.persistence.save|core.editing|enabled||Save|persistence|") != null);
    try t.expect(std.mem.indexOf(u8, primary, "core.view") == null);
    var active_buf: [1 << 14]u8 = undefined;
    const active = runStr(ed, &active_buf, "offerwatch.list", &.{.{ .integer = 0 }});
    try t.expect(std.mem.indexOf(u8, active, "|core.view|") != null);
    // The listing's own non-standard node actions are offers too, labelled as
    // the scene labels them — what a toolbar in the sidebar would show.
    try t.expect(std.mem.indexOf(u8, active, "plugin.fs.create-file|core.view|enabled||New file|fs|") != null);

    // Invoking in the primary context acts on the editor, and leaves the
    // head where it was.
    try t.expectEqualStrings("invoked", runStr(ed, &buf, "offerwatch.invoke", &.{ .{ .integer = 1 }, .{ .string = "std.history.undo" } }));
    try t.expect(ed.buffers.active_id != editor_entry);
    {
        const text = try ed.buffers.get(editor_entry).?.textEditor().?.text().toOwnedSlice(gpa);
        defer gpa.free(text);
        try t.expectEqualStrings("one\n", text);
    }
    // …which moved the editor's availability (undo spent, redo ready): one
    // event, delivered at the frame boundary rather than inside the invoke.
    try t.expectEqual(first + 1, runInt(ed, "offerwatch.fired", &.{}));
    ed.applyWindow();
    try t.expectEqual(first + 2, runInt(ed, "offerwatch.fired", &.{}));
    // A refusal says why instead of doing nothing.
    const refusal = runStr(ed, &buf, "offerwatch.invoke", &.{ .{ .integer = 1 }, .{ .string = "std.history.undo" } });
    try t.expect(std.mem.indexOf(u8, refusal, "nothing-to-undo") != null);

    // A provider registering is a change; its presentation override shows.
    try t.expectEqual(@as(i64, 1), runInt(ed, "offerwatch.provide", &.{}));
    ed.applyWindow();
    try t.expectEqual(first + 3, runInt(ed, "offerwatch.fired", &.{}));
    const probed = runStr(ed, &buf, "offerwatch.list", &.{.{ .integer = 1 }});
    try t.expect(std.mem.indexOf(u8, probed, "plugin.offerwatch.probe|plugin.offerwatch|enabled||Probe|watch|5") != null);

    // Back to the editor: the same primary context, so no event…
    ed.run("window.focus-right");
    ed.applyWindow();
    try t.expectEqual(editor_entry, ed.buffers.active_id);
    try t.expectEqual(first + 3, runInt(ed, "offerwatch.fired", &.{}));
    // …and a different entry in the primary pane is one, naming the entry.
    try openFile(ed, "b.txt", "two\n");
    ed.applyWindow();
    try t.expectEqual(first + 4, runInt(ed, "offerwatch.fired", &.{}));
    try t.expect(std.mem.indexOf(u8, runStr(ed, &buf, "offerwatch.keys", &.{}), "entry") != null);
}

test "e2e/ide: a live REPL is a key of the context — the event names it, a predicate reads it, explain agrees with the keypress" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try h.loadOfferwatch(ed);
    try openFile(ed, "a.txt", "sent line\n");
    const source = ed.buffers.active_id;
    ed.applyWindow();
    var buf: [1 << 12]u8 = undefined;
    const arms = [_][]const u8{"plugin.code.send-to-repl"};

    // Nothing publishes `repl.session`: the gated provider is not offered,
    // and explain says so exactly as a keypress would find it.
    try t.expectEqualStrings("<unset>", runStr(ed, &buf, "offerwatch.context-get", &.{.{ .string = "repl.session" }}));
    try t.expect(!offered(ed, "plugin.code.send-to-repl"));
    try t.expect(core.intent.explain(ed.ctx, &arms) == .blocked);

    // Starting one publishes it on this place, and the ONE event of that
    // frame lists it.
    ed.runStr("repl.start", "cat");
    try t.expect(std.mem.indexOf(u8, runStr(ed, &buf, "offerwatch.keys", &.{}), "repl.session") != null);
    ed.runStr("file.open", "a.txt");
    try t.expectEqual(source, ed.buffers.active_id);
    ed.applyWindow();
    // Its value is the REPL's designation: a live resource, by name.
    try t.expectEqualStrings("weft://here/proc/repl", runStr(ed, &buf, "offerwatch.context-get", &.{.{ .string = "repl.session" }}));
    // Back on the source, the entry moved — the REPL key did not.
    try t.expect(std.mem.indexOf(u8, runStr(ed, &buf, "offerwatch.keys", &.{}), "repl.session") == null);

    // Explain and the keypress read the same freshly synced table: both say
    // the config's provider runs it, and running it sends the line.
    const why = core.intent.explain(ed.ctx, &arms);
    try t.expect(why == .ready);
    try t.expectEqualStrings("config", why.ready.provider);
    try t.expect(offered(ed, "plugin.code.send-to-repl"));
    var refusal: [256]u8 = undefined;
    try t.expect(ed.ctx.intent.?.invokeNamed(ed.ctx, "plugin.code.send-to-repl", &refusal) == .invoked);
    try t.expect(h.drainToolContains(ed, "*repl*", "sent line"));

    // Quitting retracts it: one event naming the key, and nothing offered.
    const before = runInt(ed, "offerwatch.fired", &.{});
    ed.run("repl.quit");
    ed.applyWindow();
    try t.expect(runInt(ed, "offerwatch.fired", &.{}) > before);
    try t.expect(std.mem.indexOf(u8, runStr(ed, &buf, "offerwatch.keys", &.{}), "repl.session") != null);
    try t.expectEqualStrings("<unset>", runStr(ed, &buf, "offerwatch.context-get", &.{.{ .string = "repl.session" }}));
    try t.expect(core.intent.explain(ed.ctx, &arms) == .blocked);
}

test "e2e/ide: C-d adds the next occurrence, C-S-l takes them all, and typing edits every one as one undo unit" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "o.txt", "foo bar foo baz foo\n");

    // The first press selects the word under the caret; each later press adds
    // the next occurrence.
    ed.press("C-Home", "");
    ed.press("C-d", "");
    try t.expectEqual(@as(usize, 1), textEd(ed).selectionCount());
    try t.expectEqual(Span{ .start = 0, .end = 3 }, selected(ed).?);
    ed.press("C-d", "");
    ed.press("C-d", "");
    try t.expectEqual(@as(usize, 3), textEd(ed).selectionCount());
    // The newest occurrence is the primary, and it was flashed.
    try t.expectEqual(Span{ .start = 16, .end = 19 }, selected(ed).?);
    // Every occurrence is taken: another press adds nothing.
    ed.press("C-d", "");
    try t.expectEqual(@as(usize, 3), textEd(ed).selectionCount());

    // Typing replaces all three; one C-z takes all three back.
    ed.typeText("X");
    try expectText(ed, "X bar X baz X\n");
    ed.press("C-z", "");
    try expectText(ed, "foo bar foo baz foo\n");

    // Escape is back to one caret.
    ed.press("Escape", "");
    try t.expectEqual(@as(usize, 1), textEd(ed).selectionCount());

    // C-S-l from a caret inside the MIDDLE occurrence: all of them at once,
    // the one the caret was in still primary.
    ed.press("C-Home", "");
    for (0..9) |_| ed.press("Right", "");
    ed.press("C-S-l", "");
    try t.expectEqual(@as(usize, 3), textEd(ed).selectionCount());
    try t.expectEqual(Span{ .start = 8, .end = 11 }, selected(ed).?);
    ed.typeText("Y");
    try expectText(ed, "Y bar Y baz Y\n");
    ed.press("C-z", "");
    try expectText(ed, "foo bar foo baz foo\n");
}

/// How many times `needle` occurs in the focused document.
fn occurrences(ed: *Editor, needle: []const u8) !usize {
    const got = try ed.textAlloc();
    defer ed.gpa.free(got);
    return std.mem.count(u8, got, needle);
}

test "e2e/ide: after C-S-l, a click places THE caret — no stray secondary takes the typing" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "s.txt", "foo bar foo baz foo\n");
    ed.applyWindow();

    // A click places THE caret: the three occurrences C-S-l took are gone,
    // not left behind as carets the next keystroke types into.
    ed.press("C-Home", "");
    ed.press("C-S-l", "");
    try t.expectEqual(@as(usize, 3), textEd(ed).selectionCount());
    ed.click(ed.pointAt(5).?);
    try t.expectEqual(@as(usize, 1), textEd(ed).selectionCount());
    ed.typeText("!");
    try expectText(ed, "foo b!ar foo baz foo\n");
}

test "e2e/ide: after C-S-l, a find selects its match as THE selection — no stray secondary takes the typing" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "s.txt", "foo bar foo baz foo\n");

    ed.press("C-Home", "");
    ed.press("C-S-l", "");
    try t.expectEqual(@as(usize, 3), textEd(ed).selectionCount());
    ed.press("C-f", "");
    ed.typeText("bar");
    ed.press("Return", "\n");
    ed.press("Escape", "");
    try t.expectEqual(@as(usize, 1), textEd(ed).selectionCount());
    ed.typeText("!");
    try t.expectEqual(@as(usize, 1), try occurrences(ed, "!"));
}

test "e2e/ide: closing a background tab is no navigation — the jumplist and buffer-back are untouched" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "a.txt", "alpha\n");
    const a = ed.buffers.active_id;
    try openFile(ed, "b.txt", "beta\n");
    const b = ed.buffers.active_id;
    try openFile(ed, "c.txt", "gamma\n");
    var pixels = try ed.renderComposite();
    gpa.free(pixels);
    ed.click(ed.pointAtTab(a, .body) orelse return error.NoTab);
    try t.expectEqual(a, ed.buffers.active_id);
    const jumps = ed.head.jumps.items.items.len;
    const prev = ed.buffers.prev_id;

    // A middle click borrows b to close it and comes straight back to a.
    pixels = try ed.renderComposite();
    gpa.free(pixels);
    ed.clickWith(ed.pointAtTab(b, .body) orelse return error.NoTab, 2, .{});
    try t.expect(ed.buffers.get(b) == null);
    try t.expectEqual(a, ed.buffers.active_id);
    try t.expectEqual(jumps, ed.head.jumps.items.items.len);
    try t.expectEqual(prev, ed.buffers.prev_id);
}

test "e2e/ide: a double click selects a word, a triple click the line, and C-click adds a caret" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "p.txt", "alpha beta gamma\nsecond line\n");
    ed.applyWindow();

    const at = ed.pointAt(7).?; // inside `beta`
    ed.click(at);
    try t.expect(selected(ed) == null);
    ed.clickAgain(at);
    try t.expectEqual(Span{ .start = 6, .end = 10 }, selected(ed).?);
    ed.clickAgain(at);
    try t.expectEqual(Span{ .start = 0, .end = 17 }, selected(ed).?);

    // A plain click, then C-click elsewhere: two carets, typing at both.
    ed.click(ed.pointAt(0).?);
    ed.clickWith(ed.pointAt(17).?, 1, .{ .ctrl = true });
    try t.expectEqual(@as(usize, 2), textEd(ed).selectionCount());
    ed.typeText(">");
    try expectText(ed, ">alpha beta gamma\n>second line\n");
    ed.press("C-z", "");
    try expectText(ed, "alpha beta gamma\nsecond line\n");
}

test "e2e/ide: C-c / C-x / C-v ride the system clipboard, and text copied elsewhere pastes" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "q.txt", "one two\n");

    // Select `one`, copy: the clipboard has it.
    ed.press("Home", "");
    for (0..3) |_| ed.press("S-Right", "");
    ed.press("C-c", "");
    try t.expectEqualStrings("one", ed.head.clipboard.text());
    // Paste it at the end of the line: the register and the clipboard agree,
    // so it is the register that pastes.
    ed.press("End", "");
    ed.press("C-v", "");
    try expectText(ed, "one twoone\n");

    // Something else took the clipboard: C-v pastes THAT.
    try ed.head.clipboard.set(gpa, "EXT");
    ed.press("C-v", "");
    try expectText(ed, "one twooneEXT\n");

    // Cut puts the text on the clipboard as well.
    ed.press("Home", "");
    for (0..3) |_| ed.press("S-Right", "");
    ed.press("C-x", "");
    try expectText(ed, " twooneEXT\n");
    try t.expectEqualStrings("one", ed.head.clipboard.text());
}

test "e2e/ide: long moves leave a jump — M-Left comes back from C-End and from C-g" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "r.txt", "l1\nl2\nl3\nl4\nl5\n");

    ed.press("Down", "");
    const from = cursor(ed);
    ed.press("C-End", "");
    try t.expect(cursor(ed) != from);
    ed.press("M-Left", "");
    try t.expectEqual(from, cursor(ed));
    ed.press("M-Right", "");
    try t.expect(cursor(ed) != from);

    // C-g 4: line 4, and back.
    ed.press("C-Home", "");
    ed.press("C-g", "");
    ed.typeText("4");
    ed.press("Return", "");
    try t.expectEqual(@as(usize, 9), cursor(ed));
    ed.press("M-Left", "");
    try t.expectEqual(@as(usize, 0), cursor(ed));
}

/// The flash set on the active entry right now.
fn flashed(ed: *Editor, out: []core.flash.Range) []core.flash.Range {
    return ed.caps.flash.ranges(&ed.caps.layers, &textEd(ed).doc, out);
}

test "e2e/ide: C-S-l flashes every occurrence it selects, not only the last" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "fl.txt", "foo bar foo baz foo\n");

    ed.press("C-Home", "");
    ed.press("C-S-l", "");
    try t.expectEqual(@as(usize, 3), textEd(ed).selectionCount());
    var out: [8]core.flash.Range = undefined;
    const set = flashed(ed, &out);
    try t.expectEqual(@as(usize, 3), set.len);
    try t.expectEqual(@as(usize, 0), set[0].start);
    try t.expectEqual(@as(usize, 8), set[1].start);
    try t.expectEqual(@as(usize, 16), set[2].start);
}

test "e2e/ide: C-c, C-x and C-v act at every selection — the cut is one undo unit, the paste distributes" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "cx.txt", "foo foo\n");

    ed.press("C-Home", "");
    ed.press("C-d", "");
    ed.press("C-d", "");
    try t.expectEqual(@as(usize, 2), textEd(ed).selectionCount());

    // C-x takes BOTH, and one C-z brings both back.
    ed.press("C-x", "");
    try expectText(ed, " \n");
    ed.press("C-z", "");
    try expectText(ed, "foo foo\n");

    // Cut again, then paste: two carets, two values — each its own.
    ed.press("Escape", "");
    ed.press("C-Home", "");
    ed.press("C-d", "");
    ed.press("C-d", "");
    ed.press("C-x", "");
    try expectText(ed, " \n");
    try t.expectEqual(@as(usize, 2), textEd(ed).selectionCount());
    ed.press("C-v", "");
    try expectText(ed, "foo foo\n");
    ed.press("C-z", "");
    try expectText(ed, " \n");
    ed.press("C-v", "");
    try expectText(ed, "foo foo\n");

    // Text copied elsewhere goes in at every selection too.
    try ed.head.clipboard.set(gpa, "Z");
    ed.press("C-v", "");
    try expectText(ed, "fooZ fooZ\n");
}

test "e2e/ide: moves and line edits act at every selection, and Escape collapses" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    //                          0     6   10
    try openFile(ed, "mv.txt", "foo x\nbar\nfoo y\n");

    // End moves every caret, so `;` lands at both ends.
    ed.press("C-Home", "");
    ed.press("C-d", "");
    ed.press("C-d", "");
    ed.press("End", "");
    try t.expectEqual(@as(usize, 2), textEd(ed).selectionCount());
    ed.typeText(";");
    try expectText(ed, "foo x;\nbar\nfoo y;\n");

    // Smart Home, then S-End: both lines selected.
    ed.press("Home", "");
    ed.press("S-End", "");
    try t.expectEqual(@as(usize, 2), textEd(ed).selectionCount());
    try t.expectEqual(Span{ .start = 11, .end = 17 }, selected(ed).?);
    // Tab indents both lines (not the one between), as one undo unit.
    ed.press("Tab", "\t");
    try expectText(ed, "  foo x;\nbar\n  foo y;\n");
    ed.press("C-z", "");
    try expectText(ed, "foo x;\nbar\nfoo y;\n");

    // Escape is one caret again.
    ed.press("Escape", "");
    try t.expectEqual(@as(usize, 1), textEd(ed).selectionCount());

    // C-S-k deletes every selection's line, as one undo unit.
    ed.press("C-Home", "");
    ed.press("C-d", "");
    ed.press("C-d", "");
    ed.press("C-S-k", "");
    try expectText(ed, "bar\n");
    ed.press("C-z", "");
    try expectText(ed, "foo x;\nbar\nfoo y;\n");

    // C-Return opens a line below each, and typing lands in both.
    ed.press("Escape", "");
    ed.press("C-Home", "");
    ed.press("C-d", "");
    ed.press("C-d", "");
    ed.press("C-Return", "");
    ed.typeText("z");
    try expectText(ed, "foo x;\nz\nbar\nfoo y;\nz\n");
}

test "e2e/ide: a clipboard holding the register's line plus its line break pastes the register, linewise" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "lw.txt", "one two\nbeta");

    // The last line has no line break of its own: the register holds `beta`,
    // linewise. Another editor (vim's `"+yy`) puts the same line on the
    // clipboard WITH its break — it is still the register's text.
    ed.press("C-End", "");
    ed.press("C-c", "");
    try ed.head.clipboard.set(gpa, "beta\n");
    ed.press("C-Home", "");
    for (0..4) |_| ed.press("Right", "");
    ed.press("C-v", "");
    try expectText(ed, "beta\none two\nbeta");
}

// ── The selection's mapping, declared (doc/model.md §2.6) ────────────

test "e2e/ide: a command that declares no mapping refuses several selections — the key, which-key and the echo agree" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "u.txt", "foo foo\n");
    // `region.mark` marks THE line: it says nothing about several
    // selections, so it is bound here to see how a key reaches it.
    try ed.keymap.bind(gpa, "ide", "F6", "region.mark", core.Keymap.prio_config, "test");

    // One selection is the degenerate case: it runs.
    try t.expect(explainKey(ed, "F6") == .none);

    // Two: which-key says it is blocked and why, and pressing it refuses,
    // out loud, instead of marking the primary's line alone.
    ed.press("C-Home", "");
    ed.press("C-d", "");
    ed.press("C-d", "");
    try t.expectEqual(@as(usize, 2), textEd(ed).selectionCount());
    try expectBlocked(ed, "F6", "region.mark", "one-selection");
    ed.press("F6", "");
    try t.expectEqualStrings("region.mark: acts on one selection; several are selected", ed.echoText());
    try t.expectEqual(@as(usize, 2), textEd(ed).selectionCount());
    try expectText(ed, "foo foo\n");
}

/// The name field of the files listing's row for `name`.
fn filesNameNode(ed: *Editor, name: []const u8) !h.semantic_model.scene.NodeId {
    const view_ref = ed.toolView() orelse return error.NoFilesView;
    const instance = ed.session.system.semantic.views.get(view_ref) orelse return error.StaleView;
    for (instance.scene.content.container.children) |row| {
        for (row.content.container.children) |node| {
            if (!std.mem.eql(u8, node.role, "files.name") or node.content != .field) continue;
            var snap = try ed.session.system.semantic.fields.get(node.content.field.ref).?.snapshot(ed.gpa);
            defer snap.deinit();
            if (std.mem.eql(u8, snap.value.bytes, name)) return node.id;
        }
    }
    return error.FilesNameNotFound;
}

/// How many rows of the focused listing are flagged for removal.
fn rowsFlaggedDeleted(ed: *Editor) usize {
    const instance = ed.session.system.semantic.views.get(ed.toolView() orelse return 0) orelse return 0;
    var n: usize = 0;
    for (instance.scene.content.container.children) |row| for (row.facts) |fact| {
        if (std.mem.eql(u8, fact.name, "change") and std.mem.eql(u8, fact.value, "delete")) n += 1;
    };
    return n;
}

/// Focus the files sidebar, click a.txt and C-click c.txt: two rows, two
/// extents, b.txt unmarked between them.
fn markTwoRows(ed: *Editor) !void {
    try openFile(ed, "a.txt", "x\n");
    ed.run("window.focus-left");
    ed.applyWindow();
    try t.expectEqualStrings("ide-structural", ed.mode());
    ed.click(ed.pointAtNode(try filesNameNode(ed, "a.txt")) orelse return error.RowNotDrawn);
    ed.applyWindow();
    ed.clickWith(ed.pointAtNode(try filesNameNode(ed, "c.txt")) orelse return error.RowNotDrawn, 1, .{ .ctrl = true });
    ed.applyWindow();
    try t.expectEqual(@as(usize, 2), ed.head.scene_selection.extentCount());
}

/// How the active context offers `intention`: null when nothing offers it,
/// "" when enabled, else the disabled reason code.
fn offerReason(ed: *Editor, intention: []const u8) ?[]const u8 {
    const plane = ed.ctx.intent orelse return null;
    const id = plane.catalog.findIntention(intention) orelse return null;
    const snap = plane.snapshotFor(ed.ctx) orelse return null;
    for (snap.candidates) |c| if (c.intention == id) return switch (c.availability) {
        .disabled => |d| d.reason,
        else => "",
    };
    return null;
}

test "e2e/ide: C-click marks rows in the files sidebar, Delete removes every one, and a one-row action is disabled with the reason" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| try core.file.writeBytes(gpa, name, "x\n");
    try markTwoRows(ed);
    // The view washes both as selected.
    const rows = core.selection.read(ed.ctx, gpa) catch return error.OutOfMemory;
    defer gpa.free(rows.extents);
    try t.expectEqual(@as(usize, 2), rows.extents.len);
    try t.expectEqual(core.selection.Kind.rows, rows.extents[0].kind);

    // An action a row offers for ITSELF says nothing about two rows: the
    // toolbar and the context menu read it disabled, with the reason.
    const plane = ed.ctx.intent.?;
    const snap = plane.snapshotFor(ed.ctx).?;
    var disabled_one: bool = false;
    for (snap.candidates) |c| switch (c.availability) {
        .disabled => |d| disabled_one = disabled_one or std.mem.eql(u8, d.reason, "one-selection"),
        else => {},
    };
    try t.expect(disabled_one);

    // A command that maps over TEXT targets has none to find among rows: it
    // is refused on both, never run once on the primary.
    const counted = struct {
        var runs: usize = 0;
        fn run(_: *core.command.Context, _: struct {}) anyerror!core.command.Value {
            runs += 1;
            return .nil;
        }
    };
    _ = try ed.ctx.commands.bind(gpa, "t-over-lines", core.command.define("t-over-lines", "", counted.run).maps(.{ .each = .{ .over = "line-range" } }));
    try t.expectError(error.UntargetableExtents, core.command.run(ed.ctx.commands, ed.ctx, "t-over-lines", &.{}));
    try t.expectEqual(@as(usize, 0), counted.runs);

    // Delete maps over the rows: both are flagged, b.txt between them is not.
    ed.press("Delete", "");
    try t.expectEqual(@as(usize, 2), rowsFlaggedDeleted(ed));

    // A plain click is THE selection again.
    ed.click(ed.pointAtNode(try filesNameNode(ed, "b.txt")) orelse return error.RowNotDrawn);
    ed.applyWindow();
    try t.expectEqual(@as(usize, 1), ed.head.scene_selection.extentCount());
}

/// Whether a buffer holds the project file `name`.
fn fileOpen(ed: *Editor, name: []const u8) bool {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = core.file.processDirectory(&cwd_buf) orelse return false;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, name }) catch return false;
    return ed.buffers.findByPath(path) != null;
}

test "e2e/ide: files-enter over two marked rows opens both — a plugin's command maps as IT declares, never as its table's default" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| try core.file.writeBytes(gpa, name, "x\n");
    try openFile(ed, "b.txt", "x\n");
    ed.run("window.focus-left");
    ed.applyWindow();
    ed.click(ed.pointAtNode(try filesNameNode(ed, "a.txt")) orelse return error.RowNotDrawn);
    ed.applyWindow();
    ed.clickWith(ed.pointAtNode(try filesNameNode(ed, "c.txt")) orelse return error.RowNotDrawn, 1, .{ .ctrl = true });
    ed.applyWindow();
    try t.expectEqual(@as(usize, 2), ed.head.scene_selection.extentCount());
    // (ide opens a row on one click, so a.txt is open already; the C-click
    // only MARKS c.txt.)
    try t.expect(!fileOpen(ed, "c.txt"));

    // `target.open` is `target.open` by name, and maps as it does:
    // each marked row opens. A table-wide `.whole` ran it once, on the
    // primary, and the other row was silently not opened.
    ed.run("target.open");
    try t.expect(fileOpen(ed, "a.txt"));
    try t.expect(fileOpen(ed, "c.txt"));
}

/// The names of the focused listing's rows whose pending change is `change`,
/// in view order, joined by spaces.
pub fn rowsChanged(ed: *Editor, change: []const u8, buf: []u8) ![]const u8 {
    const instance = ed.session.system.semantic.views.get(ed.toolView() orelse return error.NoFilesView) orelse return error.StaleView;
    var len: usize = 0;
    for (instance.scene.content.container.children) |row| {
        const hit = for (row.facts) |fact| {
            if (std.mem.eql(u8, fact.name, "change") and std.mem.eql(u8, fact.value, change)) break true;
        } else false;
        if (!hit) continue;
        for (row.content.container.children) |node| {
            if (!std.mem.eql(u8, node.role, "files.name") or node.content != .field) continue;
            var snap = try ed.session.system.semantic.fields.get(node.content.field.ref).?.snapshot(ed.gpa);
            defer snap.deinit();
            if (len > 0) {
                buf[len] = ' ';
                len += 1;
            }
            @memcpy(buf[len..][0..snap.value.bytes.len], snap.value.bytes);
            len += snap.value.bytes.len;
        }
    }
    return buf[0..len];
}

test "e2e/ide: copy of several marked rows is one transfer — paste lands every row, in order" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| try core.file.writeBytes(gpa, name, "x\n");
    try markTwoRows(ed);

    // Copy reads the whole set: ONE request naming both rows, one transfer
    // holding both — not two runs each overwriting the one captured value.
    ed.run("selection.copy");
    try t.expectEqual(@as(usize, 2), ed.head.scene_selection.extentCount());

    // Paste after b.txt, one row focused: both copies land, a.txt's first.
    ed.click(ed.pointAtNode(try filesNameNode(ed, "b.txt")) orelse return error.RowNotDrawn);
    ed.applyWindow();
    try t.expectEqual(@as(usize, 1), ed.head.scene_selection.extentCount());
    ed.run("selection.paste-after");
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("a.txt c.txt", try rowsChanged(ed, "copy", &buf));
}

test "e2e/ide: a one-row verb on several marked rows is refused — Rename, insert beside and step out act on one row, and the offers say so" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| try core.file.writeBytes(gpa, name, "x\n");
    try markTwoRows(ed);

    // Rename (F2, the toolbar's button) edits ONE row's name: with two rows
    // marked the offer is disabled, with the reason, instead of renaming
    // the focused row alone.
    try t.expectEqualStrings("one-selection", offerReason(ed, "plugin.code.rename") orelse return error.RenameNotOffered);
    const view_ref = ed.toolView().?;
    const rows_before = ed.session.system.semantic.views.get(view_ref).?.scene.content.container.children.len;
    for ([_][]const u8{ "field.edit", "item.insert-before", "item.insert-after", "target.open-container" }) |verb|
        try t.expectError(error.UndeclaredMapping, core.command.run(ed.commands, ed.ctx, verb, &.{}));
    // F2 reaches the same refusal, and says so.
    ed.press("F2", "");
    try t.expectEqualStrings("plugin.code.rename: acts on one selection; several are selected", ed.echoText());
    // Nothing ran: no row inserted, the listing where it was, both rows
    // still marked.
    try t.expectEqualStrings("ide-structural", ed.mode());
    try t.expect(view_ref.eql(ed.toolView().?));
    try t.expectEqual(rows_before, ed.session.system.semantic.views.get(view_ref).?.scene.content.container.children.len);
    try t.expectEqual(@as(usize, 2), ed.head.scene_selection.extentCount());
}

test "e2e/ide: the palette is an IDE's — rows are labels without ids, and what ran last is listed first" {
    var app: IdeApp = undefined;
    try app.init(t.allocator);
    defer app.deinit();
    const ed = &app.ed;

    ed.press("C-S-p", "");
    ed.settle(2);
    try t.expect(ed.head.pick.active);
    // `detail = brief`: a command row is its label; the id, shape and summary
    // are not its secondary text (the key that runs it is the annotator's).
    var commands_seen: usize = 0;
    for (ed.head.pick.keys.items, ed.head.pick.docs.items) |key, doc| {
        if (std.mem.startsWith(u8, key, "std.") or std.mem.startsWith(u8, key, "plugin.")) continue;
        commands_seen += 1;
        try t.expectEqualStrings("", doc);
    }
    try t.expect(commands_seen > 0);
    app.proj.shot(ed, "ide-palette-top");

    // Run a command from it: Split Editor Right.
    ed.typeText("Split Editor Right");
    ed.press("Return", "");
    try t.expect(!ed.head.pick.active);

    // `recent = on`: opened again, it is the first row.
    ed.press("C-S-p", "");
    ed.settle(2);
    try t.expect(ed.head.pick.active);
    try t.expectEqualStrings("window.split-right", ed.head.pick.keys.items[0]);
}
