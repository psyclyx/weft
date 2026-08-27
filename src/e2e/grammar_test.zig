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
//! `std.hierarchy.toggle-expanded` is BOUND here and offered by nobody: the
//! browser projects no expandable container yet. That is stated as what it
//! is — an unavailable intention, which the gates require to be silent — and
//! becomes a toggle, with no change to this grammar or these tests' setup,
//! when in-place projection lands.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const semantic = h.semantic_model;
const App = h.App;
const authorFile = h.authorFile;

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
/// a file beside it.
fn authorTree(ed: *h.Editor) !void {
    try core.file.writeBytesMakingDirs(ed.gpa, "child", "child/inner.txt", "inner\n");
    authorFile(ed, "top.txt", "top\n");
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

fn collectNames(
    ed: *h.Editor,
    gpa: std.mem.Allocator,
    node: semantic.scene.Node,
    out: *std.ArrayList([]u8),
) !void {
    switch (node.content) {
        .container => |c| for (c.children) |child| try collectNames(ed, gpa, child, out),
        .field => |f| try out.append(gpa, try fieldText(ed, gpa, f.ref)),
        else => {},
    }
}

/// Every row name the focused view currently shows, in scene order.
fn rowNames(ed: *h.Editor, gpa: std.mem.Allocator) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    const view = focusedView(ed) orelse return error.TestExpectedEqual;
    try collectNames(ed, gpa, view.scene, &out);
    return out;
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

    // Tab — std.hierarchy.toggle-expanded — is bound and offered by nobody
    // here: the browser projects no expandable container yet, so the key is
    // UNAVAILABLE and the view is untouched (GATE 2 states the whole rule).
    // In-place expansion is the editable-projection wave's; when it lands
    // this key reveals `inner.txt` with no change to this grammar.
    try focusRowByName(ed, gpa, "child");
    ed.press("Tab", "\t");
    try t.expectEqual(view_ref, ed.head.semantic_focus.path().?.view);
    {
        var names = try rowNames(ed, gpa);
        defer freeNames(gpa, &names);
        try t.expect(indexOfName(names.items, "child") != null);
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

    // (2) In a structural context, on a row whose hierarchy nothing offers to
    // open, Tab does nothing at all: no insertion, no error, no mode change.
    // The structural mode commits no text, so the unresolved intention cannot
    // fall through to a keystroke's bytes.
    {
        var app: GrammarApp = undefined;
        try app.init(gpa);
        defer app.deinit();
        const ed = &app.ed;
        try authorTree(ed);
        ed.runStr("open", ".");
        try focusRowByName(ed, gpa, "child"); // a directory row: still no offer
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
