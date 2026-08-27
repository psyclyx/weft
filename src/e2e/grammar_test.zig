//! e2e test file — the Phase-3 conformance gates
//! (doc/contextual-workspace-architecture.md §18 "Workspace and input"):
//! a SYNTHETIC third-party grammar (src/guest/gramtest.zig) binding only
//! `std.*` intentions gets the same Files behavior the shipped grammars do,
//! Tab is never text, and a key no grammar binds synthesizes nothing.
//!
//! The gate config loads the file browser and that grammar and NOTHING else
//! — no vim, helix, or emacs — so every key below is one the synthetic
//! grammar bound to a standard intention that the focused view resolves.
//!
//! `std.hierarchy.toggle-expanded` is BOUND here and offered by the rows that
//! own children — the browser advertises the open/close route on a directory
//! row and on nothing else — so the same key folds a directory open and stays
//! silent on a file.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const semantic = h.semantic_model;
const App = h.App;

/// The whole configuration under test (doc/configuration.md §5.2): two
/// `weft.plugin` declarations, no bindings of its own — the grammar owns
/// its table, and it is written against protocols, not against Files.
const gate_config =
    \\weft.plugin("files");
    \\weft.plugin("gramtest");
;

/// A booted weft driven ONLY by the synthetic grammar, in a throwaway project
/// that is the process cwd.
const GrammarApp = struct {
    proj: h.Project = undefined,
    ed: h.Editor = undefined,
    loader: h.ConfigLoader = undefined,

    fn init(self: *GrammarApp, gpa: std.mem.Allocator) !void {
        try self.proj.init(gpa);
        errdefer self.proj.deinit();
        try h.Editor.init(gpa, &self.ed);
        errdefer self.ed.deinit();
        self.loader = .{ .ed = &self.ed };
        errdefer self.loader.deinit();
        try core.quickjs.evalConfig(&self.ed.engine, self.ed.ctx, self.loader.loader(), &self.ed.config_kv, null, gate_config);
        try t.expectEqual(@as(usize, 0), self.loader.missing.items.len);
        try t.expectEqual(@as(usize, 0), self.loader.failed.items.len);
        // Mirror main.zig: the grammar's own mode is where a fresh buffer rests.
        try self.ed.buffers.setDefaultMode(self.ed.gpa, self.ed.head.currentMode());
        try t.expectEqualStrings("gramtest", self.ed.mode());
    }

    fn deinit(self: *GrammarApp) void {
        self.loader.deinit();
        self.ed.deinit();
        self.proj.deinit();
    }
};

/// The fixture tree the dired e2e drives: a directory with a file in it, plus
/// a file beside it. Written to disk directly — this grammar has no insert
/// mode to author through.
fn authorTree(ed: *h.Editor) !void {
    try core.file.writeBytesMakingDirs(ed.gpa, "child", "child/inner.txt", "inner\n");
    try core.file.writeBytes(ed.gpa, "top.txt", "top\n");
}

fn focusedView(ed: *h.Editor) ?*const h.view_runtime.view.Instance {
    const path = ed.head.semantic_focus.path() orelse return null;
    return ed.session.system.semantic.views.get(path.view);
}

fn fieldText(ed: *h.Editor, gpa: std.mem.Allocator, ref: semantic.scene.FieldRef) ![]u8 {
    var snap = try ed.session.system.semantic.fields.get(ref).?.snapshot(gpa);
    defer snap.deinit();
    return gpa.dupe(u8, snap.value.bytes);
}

/// The name column of every row the focused view currently shows, in scene
/// order. `column` is where the projection placed it, which is how nesting
/// reaches the surface.
fn rowNames(ed: *h.Editor, gpa: std.mem.Allocator) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    const view = focusedView(ed) orelse return error.TestExpectedEqual;
    for (view.scene.content.container.children) |row| {
        const name = nameNode(row) orelse continue;
        try out.append(gpa, try fieldText(ed, gpa, name.content.field.ref));
    }
    return out;
}

/// A files row's editable name column, the one focus traversal stops on.
fn nameNode(row: semantic.scene.Node) ?semantic.scene.Node {
    const columns = switch (row.content) {
        .container => |c| c.children,
        else => return null,
    };
    for (columns) |column| if (column.focusable and column.content == .field) return column;
    return null;
}

/// Where the projection placed a named row's name column.
fn nameColumn(ed: *h.Editor, gpa: std.mem.Allocator, want: []const u8) !?u16 {
    const view = focusedView(ed) orelse return error.TestExpectedEqual;
    for (view.scene.content.container.children) |row| {
        const name = nameNode(row) orelse continue;
        const text = try fieldText(ed, gpa, name.content.field.ref);
        defer gpa.free(text);
        if (std.mem.eql(u8, text, want)) return name.layout.column;
    }
    return null;
}

fn freeNames(gpa: std.mem.Allocator, names: *std.ArrayList([]u8)) void {
    for (names.items) |s| gpa.free(s);
    names.deinit(gpa);
}

fn indexOfName(names: []const []u8, want: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, want)) return i;
    return null;
}

/// The name of the row the head's semantic focus rests on.
fn focusedName(ed: *h.Editor, gpa: std.mem.Allocator) ![]u8 {
    const path = ed.head.semantic_focus.path() orelse return error.TestExpectedEqual;
    const view = ed.session.system.semantic.views.get(path.view) orelse return error.TestExpectedEqual;
    const leaf = path.leaf() orelse return error.TestExpectedEqual;
    const node = view.node(leaf) orelse return error.TestExpectedEqual;
    return switch (node.content) {
        .field => |f| try fieldText(ed, gpa, f.ref),
        else => error.TestExpectedEqual,
    };
}

/// Walk the rows with the grammar's own `j` until `want` has the focus. Only
/// std intentions are pressed; failing to arrive is a failed gate.
fn focusRowByName(ed: *h.Editor, gpa: std.mem.Allocator, want: []const u8) !void {
    var names = try rowNames(ed, gpa);
    defer freeNames(gpa, &names);
    var steps: usize = 0;
    while (steps <= names.items.len) : (steps += 1) {
        const at = try focusedName(ed, gpa);
        defer gpa.free(at);
        if (std.mem.eql(u8, at, want)) return;
        ed.press("j", "j");
    }
    return error.TestExpectedEqual;
}

/// The active buffer's text, or null when the workspace entry holds no
/// document at all (a projection).
fn documentText(ed: *h.Editor, gpa: std.mem.Allocator) !?[]u8 {
    const te = ed.buffers.active().textEditor() orelse return null;
    return try te.text().toOwnedSlice(gpa);
}

test "e2e/grammar: GATE 1 — a synthetic std-only grammar drives Files like the shipped ones" {
    const gpa = t.allocator;
    var app: GrammarApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try authorTree(ed);

    ed.runStr("open", ".");
    const view_ref = ed.head.semantic_focus.path().?.view;
    try t.expectEqualStrings("files", focusedView(ed).?.scene.role);

    // The tree is on the surface, and the focus starts on a row.
    {
        var names = try rowNames(ed, gpa);
        defer freeNames(gpa, &names);
        try t.expect(indexOfName(names.items, "child") != null);
        try t.expect(indexOfName(names.items, "top.txt") != null);
    }

    // `j`/`k` — std.navigation.down / .up — move between rows.
    {
        const first = try focusedName(ed, gpa);
        defer gpa.free(first);
        ed.press("j", "j");
        const second = try focusedName(ed, gpa);
        defer gpa.free(second);
        try t.expect(!std.mem.eql(u8, first, second));
        ed.press("k", "k");
        const back = try focusedName(ed, gpa);
        defer gpa.free(back);
        try t.expectEqualStrings(first, back);
    }

    // Tab — std.hierarchy.toggle-expanded — folds the focused directory open
    // IN PLACE: `inner.txt` joins the rows already on the surface, under the
    // row it belongs to, in the same view and with the same row focused.
    // Pressing it again folds it shut. The grammar names no plugin, no
    // directory, and no expansion command.
    try focusRowByName(ed, gpa, "child");
    ed.press("Tab", "\t");
    try t.expectEqual(view_ref, ed.head.semantic_focus.path().?.view);
    {
        var names = try rowNames(ed, gpa);
        defer freeNames(gpa, &names);
        const parent = indexOfName(names.items, "child") orelse return error.TestExpectedEqual;
        const child = indexOfName(names.items, "inner.txt") orelse return error.TestExpectedEqual;
        try t.expectEqual(parent + 1, child);
        // Depth reaches the surface as the name column the projection chose;
        // no second renderer and no nested view are involved.
        const parent_column = (try nameColumn(ed, gpa, "child")).?;
        const child_column = (try nameColumn(ed, gpa, "inner.txt")).?;
        try t.expect(child_column > parent_column);
        const focused = try focusedName(ed, gpa);
        defer gpa.free(focused);
        try t.expectEqualStrings("child", focused);
    }
    ed.press("Tab", "\t");
    {
        var names = try rowNames(ed, gpa);
        defer freeNames(gpa, &names);
        try t.expect(indexOfName(names.items, "child") != null);
        try t.expect(indexOfName(names.items, "inner.txt") == null);
    }

    // Return — std.target.activate — acts on the focused row's target the way
    // its kind defines as primary: the directory plugin claims it and projects
    // its contents. The grammar names neither the plugin nor the kind.
    const browser_entry = ed.buffers.active().id;
    ed.press("Return", "\r");
    const child_view = ed.head.semantic_focus.path().?.view;
    try t.expect(!child_view.eql(view_ref));
    {
        var names = try rowNames(ed, gpa);
        defer freeNames(gpa, &names);
        try t.expect(indexOfName(names.items, "inner.txt") != null);
    }

    // `q` — std.navigation.back — leaves the browser: the workspace moves to
    // another entry and no view holds the focus.
    ed.press("q", "q");
    try t.expect(ed.buffers.active().id != browser_entry);
    try t.expect(ed.head.semantic_focus.path() == null);

    // Return on a FILE row is the same key, the same intention, and the same
    // route: no tool claims a file, so the shell's placement policy opens it
    // as an ordinary editor entry. The grammar names neither files nor
    // buffers, and the browser is left exactly where it was.
    ed.runStr("open", ".");
    const files_view = ed.head.semantic_focus.path().?.view;
    const files_entry = ed.buffers.active().id;
    try focusRowByName(ed, gpa, "top.txt");
    ed.press("Return", "\r");
    try t.expect(ed.buffers.active().id != files_entry);
    {
        const text = (try documentText(ed, gpa)).?;
        defer gpa.free(text);
        try t.expectEqualStrings("top\n", text);
    }
    // The browser entry and its view survive untouched — activating a row
    // navigated the workspace, not the browser.
    try t.expect(ed.buffers.get(files_entry) != null);
    try t.expect(ed.session.system.semantic.views.get(files_view) != null);
}

test "e2e/grammar: GATE 2 — Tab inserts where it is bound, does nothing where nothing offers it, and is never text" {
    const gpa = t.allocator;

    // (1) In a text buffer Tab still inserts — because the editing grammar
    // BINDS it to the `insert-tab` command, never because a key became text.
    {
        var app: App = undefined;
        try app.init(gpa);
        defer app.deinit();
        const ed = &app.ed;
        ed.runStr("open", "note.txt");
        ed.press("i", "");
        try t.expect(ed.keymap.lookup(ed.mode(), "Tab") != null);
        ed.press("Tab", "\t");
        const text = (try documentText(ed, gpa)).?;
        defer gpa.free(text);
        try t.expectEqualStrings("\t", text);
    }

    // (2) In a structural context, on a row that DOES offer its hierarchy,
    // the same key is the toggle — and it is still not text: the rows change,
    // the buffer holds no document to have inserted into.
    {
        var app: GrammarApp = undefined;
        try app.init(gpa);
        defer app.deinit();
        const ed = &app.ed;
        try authorTree(ed);
        ed.runStr("open", ".");
        try focusRowByName(ed, gpa, "child");

        ed.press("Tab", "\t");
        {
            var opened = try rowNames(ed, gpa);
            defer freeNames(gpa, &opened);
            try t.expect(indexOfName(opened.items, "inner.txt") != null);
        }
        try t.expect((try documentText(ed, gpa)) == null);
        try t.expectEqualStrings("gramtest", ed.mode());

        ed.press("Tab", "\t");
        var closed = try rowNames(ed, gpa);
        defer freeNames(gpa, &closed);
        try t.expect(indexOfName(closed.items, "inner.txt") == null);
    }

    // (3) On a row whose hierarchy nothing offers to open, Tab does nothing at
    // all: no insertion, no error, no mode change. The structural mode commits
    // no text, so the unresolved intention cannot fall through to a
    // keystroke's bytes.
    {
        var app: GrammarApp = undefined;
        try app.init(gpa);
        defer app.deinit();
        const ed = &app.ed;
        try authorTree(ed);
        ed.runStr("open", ".");
        try focusRowByName(ed, gpa, "top.txt"); // a file row: nothing to open
        var before = try rowNames(ed, gpa);
        defer freeNames(gpa, &before);
        const name_before = try focusedName(ed, gpa);
        defer gpa.free(name_before);

        ed.press("Tab", "\t");

        var after = try rowNames(ed, gpa);
        defer freeNames(gpa, &after);
        try t.expectEqual(before.items.len, after.items.len);
        for (before.items, after.items) |b, a| try t.expectEqualStrings(b, a);
        const name_after = try focusedName(ed, gpa);
        defer gpa.free(name_after);
        try t.expectEqualStrings(name_before, name_after);
        try t.expectEqualStrings("gramtest", ed.mode());
        try t.expectEqualStrings("", ed.echoText());
    }
}

test "e2e/grammar: GATE 3 — an unbound printable key in the files view synthesizes nothing" {
    const gpa = t.allocator;
    var app: GrammarApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try authorTree(ed);

    ed.runStr("open", ".");
    // `&` is genuinely unbound in the synthetic grammar's one mode — not a
    // binding, not a chord prefix — and that mode declares no commit command.
    try t.expect(ed.keymap.lookup("gramtest", "ampersand") == null);
    try t.expect(!ed.keymap.isPrefix("gramtest", "ampersand"));

    var before = try rowNames(ed, gpa);
    defer freeNames(gpa, &before);
    const doc_before = try documentText(ed, gpa);
    defer if (doc_before) |d| gpa.free(d);

    ed.press("ampersand", "&");

    // No draft moved (the rename field the focus rests on is untouched)...
    var after = try rowNames(ed, gpa);
    defer freeNames(gpa, &after);
    try t.expectEqual(before.items.len, after.items.len);
    for (before.items, after.items) |b, a| try t.expectEqualStrings(b, a);

    // ...and no document did either.
    const doc_after = try documentText(ed, gpa);
    defer if (doc_after) |d| gpa.free(d);
    try t.expectEqual(doc_before == null, doc_after == null);
    if (doc_before) |b| try t.expectEqualStrings(b, doc_after.?);
}
