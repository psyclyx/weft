//! e2e test file — the Phase-3 conformance gates
//! (doc/contextual-workspace-architecture.md §18 "Workspace and input"):
//! a SYNTHETIC third-party grammar (src/plugin_fixtures/gramtest.zig) binding only
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
//!
//! Index — GATE 1: parity with the shipped grammars. GATE 2: Tab is bound,
//! absent, or never text. GATE 3: an unbound key synthesizes nothing.
//! GATE 4: a std-only transfer moves identity, it does not copy it. GATE 5:
//! a structural entry rests structurally and a text entry's resting state
//! comes back. Plus, unlabeled: binding explanation names intention and
//! provider and runs nothing; capture/break-out round-trips a posture;
//! a focused editable field reports `field`; an open interaction owns
//! input first and the grammar sees exactly what it declines (§10.4).

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const semantic = h.semantic_model;
const App = h.App;

/// The whole configuration under test (doc/configuration.md §5.2): two
/// `weft.plugin` declarations plus the browser's breadth, no bindings of its
/// own — the grammar owns its table, and it is written against protocols, not
/// against Files.
///
/// The two `weft.grant` lines are the shipped config's, verbatim
/// (doc/place.md §4.1): an fs capability nobody narrows is confined to the
/// dispatching place, and the browser's typed target doors need the
/// written-down unconfined form because they prove authority against a
/// provider root rather than a path. Without them this fixture browses
/// nothing.
const gate_config =
    \\weft.grant("files", "fs_read", { root: "/" });
    \\weft.grant("files", "fs_write", { root: "/" });
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

/// The fixture tree the files e2e drives: a directory with a file in it, plus
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

/// The name of every row the focused LISTING shows, in order.
///
/// A listing is a text projection: a row is a node, its NAME is the stretch its
/// producer marked editable, and nesting reaches the surface as indent. This
/// used to walk a scene's columns and snapshot a field — which is what the
/// scene plane was chosen for, and what the text plane now gives without
/// costing search, yank or selection.
fn rowNames(ed: *h.Editor, gpa: std.mem.Allocator) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    const view = ed.buffers.active().projection orelse return error.TestExpectedEqual;
    for (view.nodes.items) |node| {
        const edit = node.editable orelse continue;
        try out.append(gpa, try gpa.dupe(u8, node.text[edit.start..@min(edit.end, node.text.len)]));
    }
    return out;
}

/// A row's INDENT, which is where nesting reaches the surface — the scene
/// carried the same fact as a layout column.
fn nameColumn(ed: *h.Editor, gpa: std.mem.Allocator, want: []const u8) !?u16 {
    _ = gpa;
    const view = ed.buffers.active().projection orelse return error.TestExpectedEqual;
    for (view.nodes.items) |node| {
        const edit = node.editable orelse continue;
        const name = node.text[edit.start..@min(edit.end, node.text.len)];
        if (!std.mem.eql(u8, name, want)) continue;
        var i: usize = 0;
        while (i < node.text.len and node.text[i] == ' ') i += 1;
        return @intCast(i);
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

/// The name of the row POINT rests on. The listing.s focus is the cursor: a
/// row is text, so "which row am I on" is where the caret is, and the answer
/// is an IDENTITY because the host hit-tests it back to a node.
fn focusedName(ed: *h.Editor, gpa: std.mem.Allocator) ![]u8 {
    const b = ed.buffers.active();
    const view = b.projection orelse return error.TestExpectedEqual;
    const editor = b.textEditor() orelse return error.TestExpectedEqual;
    const node = view.subjectAt(editor.cursorOffset()) orelse return error.TestExpectedEqual;
    const edit = node.editable orelse return error.TestExpectedEqual;
    return gpa.dupe(u8, node.text[edit.start..@min(edit.end, node.text.len)]);
}

/// Walk the rows with the grammar's own `j` until `want` has the focus,
/// rewinding with `k` first so the walk starts above every row whatever the
/// listing order. Only std intentions are pressed; failing to arrive is a
/// failed gate.
fn focusRowByName(ed: *h.Editor, gpa: std.mem.Allocator, want: []const u8) !void {
    var names = try rowNames(ed, gpa);
    defer freeNames(gpa, &names);
    for (0..names.items.len) |_| ed.press("k", "k");
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
    const listing = ed.buffers.active_id;
    try t.expectEqualStrings("files", ed.buffers.active().tool);
    try t.expect(ed.buffers.active().projection != null);

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
    try t.expectEqual(listing, ed.buffers.active_id);
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
    // A directory is its own LISTING, in its own instanced entry — the same
    // shape the scene had (a view per directory), now spelled as a buffer per
    // directory, which is what lets any of them be docked.
    try t.expect(ed.buffers.active().id != browser_entry);
    try t.expect(ed.buffers.active().projection != null);
    {
        var names = try rowNames(ed, gpa);
        defer freeNames(gpa, &names);
        try t.expect(indexOfName(names.items, "inner.txt") != null);
    }

    // `q` — std.navigation.back — leaves the browser: the workspace moves to
    // another entry and no view holds the focus.
    ed.press("q", "q");
    try t.expect(ed.buffers.active().id != browser_entry);

    // Return on a FILE row is the same key, the same intention, and the same
    // route: no tool claims a file, so the shell's placement policy opens it
    // as an ordinary editor entry. The grammar names neither files nor
    // buffers, and the browser is left exactly where it was.
    ed.runStr("open", ".");
    const files_entry = ed.buffers.active().id;
    try focusRowByName(ed, gpa, "top.txt");
    ed.press("Return", "\r");
    try t.expect(ed.buffers.active().id != files_entry);
    {
        const text = (try documentText(ed, gpa)).?;
        defer gpa.free(text);
        try t.expectEqualStrings("top\n", text);
    }
    // The browser entry survives untouched — activating a row navigated the
    // workspace, not the browser.
    try t.expect(ed.buffers.get(files_entry) != null);
    try t.expect(ed.buffers.get(files_entry).?.projection != null);
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
        // A listing HAS a document now — it is text, which is the point — so
        // the gate is not "there is nothing to insert into" but the stronger
        // one it always meant: Tab put no TAB in it.
        {
            const doc = (try documentText(ed, gpa)).?;
            defer gpa.free(doc);
            try t.expect(std.mem.indexOfScalar(u8, doc, '\t') == null);
        }
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

test "e2e/grammar: explaining a binding names its intention and provider, and runs nothing" {
    const gpa = t.allocator;
    var app: GrammarApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try authorTree(ed);

    ed.runStr("open", ".");
    // A keystroke first, exactly as in production: dispatch publishes the
    // focused view's table, and only THEN does a menu open and which-key ask.
    ed.press("j", "j");
    try focusRowByName(ed, gpa, "child");

    const focus_before = try focusedName(ed, gpa);
    defer gpa.free(focus_before);
    const entry_before = ed.buffers.active_id;
    var rows_before = try rowNames(ed, gpa);
    defer freeNames(gpa, &rows_before);

    // What which-key prints for `j`: the arm that would win, and the provider
    // that would run it — from the resolver, not from a second table.
    switch (core.intent.explain(ed.ctx, &.{"std.navigation.down"})) {
        .ready => |r| {
            try t.expectEqualStrings("std.navigation.down", r.intention);
            // Moving in a tool entry is core.s answer now, from the ACTION
            // plane, where the scene used to offer it from a focused node.
            try t.expectEqualStrings("core", r.provider);
        },
        else => return error.TestExpectedReady,
    }

    // `Tab` on the directory row: the browser offers it, so the hint names the
    // provider that would fold it open. Focus moved by command rather than by
    // keystroke, and the answer still tracks it — explaining syncs the same
    // tables dispatch would.
    switch (core.intent.explain(ed.ctx, &.{"std.hierarchy.toggle-expanded"})) {
        .ready => |r| {
            try t.expectEqualStrings("std.hierarchy.toggle-expanded", r.intention);
            // The LISTING offers folding, attributed to the plugin that binds
            // it — a derived offer names its author (`catalog.Offer.attribution`).
            try t.expectEqualStrings("plugin.files", r.provider);
        },
        else => return error.TestExpectedReady,
    }

    // The file row beside it offers nothing to open, so the same binding
    // reports the arm it leads with and why it is dead, instead of promising
    // an expansion.
    try focusRowByName(ed, gpa, "top.txt");
    switch (core.intent.explain(ed.ctx, &.{"std.hierarchy.toggle-expanded"})) {
        .blocked => |b| {
            try t.expectEqualStrings("std.hierarchy.toggle-expanded", b.intention);
            try t.expectEqualStrings("", b.provider); // nobody to name
            try t.expect(b.reason.len > 0);
        },
        else => return error.TestExpectedBlocked,
    }
    try focusRowByName(ed, gpa, "child");

    // A plain command arm is dispatch's, not the catalog's — nothing to explain.
    try t.expect(core.intent.explain(ed.ctx, &.{"open"}) == .none);

    // EXPLANATION CONVEYS NO AUTHORITY. The calls above resolved an endpoint a
    // keypress would have invoked; it was not invoked, so the focus
    // `std.navigation.down` moves has not moved, the projection is untouched,
    // and nothing was echoed.
    const focus_after = try focusedName(ed, gpa);
    defer gpa.free(focus_after);
    try t.expectEqualStrings(focus_before, focus_after);
    try t.expectEqual(entry_before, ed.buffers.active_id);
    var rows_after = try rowNames(ed, gpa);
    defer freeNames(gpa, &rows_after);
    try t.expectEqual(rows_before.items.len, rows_after.items.len);
    for (rows_before.items, rows_after.items) |b, a| try t.expectEqualStrings(b, a);
    try t.expectEqualStrings("", ed.echoText());
}

/// How many rows the focused view shows under `want`, and how many of those
/// the projection placed at `column` (its depth in the tree, on the surface).
fn countName(ed: *h.Editor, gpa: std.mem.Allocator, want: []const u8) !usize {
    return countNameAt(ed, gpa, want, null);
}

fn countNameAt(ed: *h.Editor, gpa: std.mem.Allocator, want: []const u8, column: ?u16) !usize {
    _ = gpa;
    const view = ed.buffers.active().projection orelse return error.TestExpectedEqual;
    var n: usize = 0;
    for (view.nodes.items) |node| {
        const edit = node.editable orelse continue;
        const name = node.text[edit.start..@min(edit.end, node.text.len)];
        if (!std.mem.eql(u8, name, want)) continue;
        if (column) |want_column| {
            var i: usize = 0;
            while (i < node.text.len and node.text[i] == ' ') i += 1;
            if (i != want_column) continue;
        }
        n += 1;
    }
    return n;
}

test "e2e/grammar: GATE 4 — a std-only transfer moves a row's identity, it does not copy it" {
    const gpa = t.allocator;
    var app: GrammarApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try authorTree(ed);

    ed.runStr("open", ".");
    const listing_entry = ed.buffers.active_id;

    // Open the directory in place, so ONE listing holds both ends of the move.
    try focusRowByName(ed, gpa, "child");
    ed.press("Tab", "\t");
    const nested = (try nameColumn(ed, gpa, "inner.txt")).?;

    // `d` — std.transfer.delete-to-register — captures the row INTO the
    // register. The row itself stays: what was captured is a deferred move,
    // and the register is the only thing that spans the two loci.
    try focusRowByName(ed, gpa, "top.txt");
    ed.press("d", "d");
    try t.expectEqual(@as(usize, 1), try countName(ed, gpa, "top.txt"));

    // `p` — std.transfer.paste — places it beside a row inside the directory.
    // The grammar names no plugin, no path, and no placement.
    try focusRowByName(ed, gpa, "inner.txt");
    ed.press("p", "p");
    try t.expectEqual(listing_entry, ed.buffers.active_id);
    try t.expectEqual(@as(usize, 2), try countName(ed, gpa, "top.txt"));
    try t.expectEqual(@as(usize, 1), try countNameAt(ed, gpa, "top.txt", nested));

    // Applying the draft is a MOVE, not a create: the destination is written
    // from the captured entry's own identity, so the source ceases to exist
    // without anyone staging its deletion. A paste that had ferried no
    // identity could only have created a new file and left the old one.
    ed.run("view-apply");
    ed.press("y", "y");
    try t.expect(h.drainUntilOracle(
        &app.proj,
        ed,
        "test -f child/top.txt && test ! -e top.txt && printf ok",
        "ok",
    ));
    const moved = try core.file.readAlloc(gpa, "child/top.txt");
    defer gpa.free(moved);
    try t.expectEqualStrings("top\n", moved);

    // Through the reconcile the apply drives, the listing that held the source
    // no longer shows it at ANY depth — nobody staged its removal, so its
    // absence is the move itself...
    ed.settle(4);
    try t.expectEqual(@as(usize, 0), try countName(ed, gpa, "top.txt"));
    // ...and the directory it was placed in holds it, once.
    ed.runStr("open", "child");
    try t.expectEqual(@as(usize, 1), try countName(ed, gpa, "top.txt"));
}

// ── §10.4: input postures ────────────────────────────────────────────

/// One grammar's declared answer to §10.4, as the mode-leak gate reads it.
/// The gate drives the SAME script through each: what differs is the
/// vocabulary, not the mechanism — which is the whole point of declaring a
/// posture instead of asking what tool an entry is.
const PostureCase = struct {
    /// The grammar plugin to load from the embedded bundle.
    grammar: []const u8,
    /// The key that puts this grammar in a text-committing state, or null
    /// where its RESTING state already commits (a modeless grammar) or where
    /// it has no such state at all.
    enter_text: ?[]const u8 = null,
    /// The state reached that way — asserted to commit text, so the gate
    /// proves the leak's precondition before proving it cannot leak.
    committing: ?[]const u8 = null,
    text_resting: []const u8,
    structural_resting: []const u8,
    /// The chord this grammar keeps bound for `std.input.break-out` — each
    /// picks its own, which is exactly why the vocabulary is an intention
    /// and not a key core reserves.
    break_out: []const u8,
};

const posture_cases = [_]PostureCase{
    // Vim: modal, so its text resting state commits nothing already; the
    // insert-like state is what a structural entry must not inherit.
    .{ .grammar = "vim", .enter_text = "i", .committing = "insert", .text_resting = "normal", .structural_resting = "normal", .break_out = "C-backslash" },
    // Emacs: MODELESS — its text resting state IS the committing one, so it
    // must declare a separate structural state or every letter leaks.
    .{ .grammar = "emacs", .committing = "emacs", .text_resting = "emacs", .structural_resting = "emacs-structural", .break_out = "C-c C-backslash" },
    // The synthetic std-only grammar: one state, committing nothing, and it
    // DECLARES that as its answer for both postures rather than defaulting.
    .{ .grammar = "gramtest", .text_resting = "gramtest", .structural_resting = "gramtest", .break_out = "C-backslash" },
};

test "e2e/grammar: GATE 5 — a structural entry rests structurally, and the text entry's resting state comes back" {
    const gpa = t.allocator;
    for (posture_cases) |case| {
        var ed: h.Editor = undefined;
        try h.Editor.init(gpa, &ed);
        defer ed.deinit();
        try h.loadGrammar(&ed, case.grammar);

        // A text entry: the full grammar applies, by DERIVATION — nobody
        // declared anything about the scratch buffer.
        const text_id = ed.buffers.active_id;
        try t.expectEqual(core.input.Posture.text, ed.ctx.posture());
        try t.expectEqualStrings(case.text_resting, ed.mode());

        // Get into the state text comes from, and prove it is one.
        if (case.enter_text) |key| ed.press(key, key);
        if (case.committing) |committing| {
            try t.expectEqualStrings(committing, ed.mode());
            try t.expect(ed.keymap.commitCommand(committing) != null);
        }

        // Enter a STRUCTURAL entry (a view entry holds no text, so it derives
        // `structural` — no tool had to declare anything).
        const view_id = try ed.buffers.createView(gpa, "*view*", "tool");
        try ed.buffers.switchTo(gpa, view_id, ed.head, ed.keymap);

        try t.expectEqual(core.input.Posture.structural, ed.ctx.posture());
        // THE MODE-LEAK CLASS: the entry rests in the grammar's structural
        // state, and no key in that state can become text — by declaration,
        // not by refusing edits after the fact.
        try t.expectEqualStrings(case.structural_resting, ed.mode());
        try t.expectEqual(@as(?[]const u8, null), ed.keymap.commitCommand(ed.mode()));

        // The grammar DECLINES its insert-like state here rather than parking
        // the user in it.
        if (case.enter_text) |key| {
            ed.press(key, key);
            try t.expectEqualStrings(case.structural_resting, ed.mode());
        }

        // Returning restores the TEXT entry's resting state — the entry left
        // mid-insert comes back at its base, not in insert.
        try ed.buffers.switchTo(gpa, text_id, ed.head, ed.keymap);
        try t.expectEqual(core.input.Posture.text, ed.ctx.posture());
        try t.expectEqualStrings(case.text_resting, ed.mode());
    }
}

test "e2e/grammar: a capture declaration round-trips, and break-out returns the posture it displaced" {
    const gpa = t.allocator;
    for (posture_cases) |case| {
        var ed: h.Editor = undefined;
        try h.Editor.init(gpa, &ed);
        defer ed.deinit();
        try h.loadGrammar(&ed, case.grammar);
        try h.loadHeadtest(&ed); // `head-capture`: a presentation owner, across the membrane

        // No capture consumer exists in-tree (§10.4), so what is wired is the
        // DECLARATION and its pairing: a presentation declares capture on its
        // entry, the read reports it, and the grammar's always-retained
        // break-out chord returns the posture capture displaced.
        const view_id = try ed.buffers.createView(gpa, "*view*", "tool");
        try ed.buffers.switchTo(gpa, view_id, ed.head, ed.keymap);
        try t.expectEqual(core.input.Posture.structural, ed.ctx.posture());

        ed.run("head-capture");
        try t.expectEqual(core.input.Posture.capture, ed.ctx.posture());
        // A capture entry still rests where its grammar answers keys, so the
        // break-out chord can be pressed at all.
        try t.expectEqualStrings(case.structural_resting, ed.mode());

        ed.chord(case.break_out);
        try t.expectEqual(core.input.Posture.structural, ed.ctx.posture());

        // The DISPLACED declaration comes back, not merely "the derivation":
        // an owner that declared `text` on a text-less entry gets that back.
        // (An in-process presentation owner declares through the same door a
        // guest's `weft.declarePosture` funnels into.)
        ed.buffers.active().declarePosture(.text);
        ed.run("head-capture");
        ed.chord(case.break_out);
        try t.expectEqual(core.input.Posture.text, ed.ctx.posture());
    }
}

test "e2e/grammar: a focused editable field reports `field`, and rests where structural rests" {
    const gpa = t.allocator;
    var app: GrammarApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try authorTree(ed);

    // Point on a row.s editable NAME is a FIELD: commits belong to it, not to
    // the listing at large (§11.8). That is a refinement of `structural`, not a
    // departure from it — the entry still rests where the grammar.s structural
    // state is, which is what keeps the browser.s own keys live while a name is
    // being typed.
    ed.runStr("open", ".");
    try focusRowByName(ed, gpa, "top.txt");
    // Point rests on the row.s NAME, which is the part its producer marked
    // editable — so the posture is `field` there and `structural` elsewhere in
    // the same entry. The refinement is per-ROW now rather than per-entry,
    // which is what a listing made of text can say and a scene could not.
    try t.expectEqual(core.input.Posture.field, ed.ctx.posture());
    try t.expectEqualStrings("gramtest", ed.mode());
    try t.expectEqualStrings("gramtest", ed.buffers.restingModeFor(.field));
}

test "e2e/grammar: an open interaction owns input first, and the grammar sees exactly what it declines" {
    const gpa = t.allocator;
    var app: GrammarApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try authorTree(ed);

    ed.runStr("open", ".");
    try focusRowByName(ed, gpa, "child");
    ed.press("Tab", "\t");
    try focusRowByName(ed, gpa, "top.txt");
    ed.press("d", "d");
    try focusRowByName(ed, gpa, "inner.txt");
    ed.press("p", "p");

    // Applying the draft asks first: an interaction goes on the head's stack.
    ed.run("view-apply");
    try t.expect(ed.head.interactions.active() != null);

    // §10.4's standing precedence rule (enforced in `dispatchSpec`, which
    // offers every key to `invokeInteractionInput` BEFORE the keymap): the
    // interaction declines `j`/`k`, so the grammar still navigates under an
    // open dialog — and the dialog stays up, because declining is not
    // dismissing.
    try focusRowByName(ed, gpa, "child");
    try t.expect(ed.head.interactions.active() != null);
    {
        const at = try focusedName(ed, gpa);
        defer gpa.free(at);
        try t.expectEqualStrings("child", at);
    }

    // A key it DOES bind never reaches the grammar. `y` is this grammar's
    // std.transfer.yank; here it confirms and the interaction closes — had
    // the grammar seen it, the dialog would still be open and the draft
    // unapplied.
    ed.press("y", "y");
    try t.expect(ed.head.interactions.active() == null);
    try t.expect(h.drainUntilOracle(
        &app.proj,
        ed,
        "test -f child/top.txt && test ! -e top.txt && printf ok",
        "ok",
    ));
}
