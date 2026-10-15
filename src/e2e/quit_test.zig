//! e2e test file — quitting with unsaved work. `app.quit` is an action: core's
//! floor refuses and names what would be lost; the `buffers` plugin provides
//! one that ASKS — save all and quit, quit without saving, or cancel. The `:`
//! line's `!` forces, and `:wq`/`:wqa` wait for their saves to land before
//! quitting (`file.when-saved`). Every gate reads what a person would: the
//! question, the echo line, the bytes on disk, and whether the editor quit.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const Editor = h.Editor;
const Project = h.Project;

/// A vim workspace (which includes `buffers`, the asking provider) in a fresh
/// project directory.
const Fixture = struct {
    proj: Project = undefined,
    ed: Editor = undefined,

    fn init(self: *Fixture, comptime load: fn (*Editor) anyerror!void) !void {
        try self.proj.init(t.allocator);
        errdefer self.proj.deinit();
        try Editor.init(t.allocator, &self.ed);
        errdefer self.ed.deinit();
        try load(&self.ed);
    }

    fn deinit(self: *Fixture) void {
        self.ed.deinit();
        self.proj.deinit();
    }

    fn quit(self: *Fixture) bool {
        return self.ed.session.system.quit;
    }
};

/// Open `name` (written with `body`) and add `typed` at its start in insert
/// mode: a file with unsaved edits.
fn openDirty(ed: *Editor, name: []const u8, body: []const u8, typed: []const u8) !core.Buffers.Id {
    try core.file.writeBytes(ed.gpa, name, body);
    ed.runStr("file.open", name);
    ed.press("i", "");
    ed.typeText(typed);
    ed.press("Escape", "");
    try t.expect(try ed.buffers.active().hasUnsavedFile(ed.gpa));
    return ed.buffers.active_id;
}

/// Type `line` on the `:` line and run it.
fn ex(ed: *Editor, line: []const u8) void {
    ed.press("colon", "");
    ed.typeText(line);
    ed.press("Return", "");
}

/// Answer the open question with the row whose text is `answer`.
fn choose(ed: *Editor, answer: []const u8) !void {
    try t.expect(ed.pick.active);
    ed.typeText(answer);
    ed.settle(2);
    try t.expectEqual(@as(usize, 1), ed.pick.filtered.items.len);
    try t.expectEqualStrings(answer, ed.pick.items.items[ed.pick.filtered.items[0]]);
    ed.run("pick.accept");
}

fn expectOnDisk(ed: *Editor, name: []const u8, want: []const u8) !void {
    const got = try core.file.readAlloc(ed.gpa, name);
    defer ed.gpa.free(got);
    try t.expectEqualStrings(want, got);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "e2e/quit: `:q!` quits over unsaved edits" {
    var f: Fixture = .{};
    try f.init(h.loadWorkspace);
    defer f.deinit();
    _ = try openDirty(&f.ed, "a.txt", "alpha\n", "x");
    ex(&f.ed, "q!");
    try t.expect(f.quit());
    try t.expect(!f.ed.pick.active);
}

test "e2e/quit: `:q` over unsaved edits ASKS, naming them; Cancel and Escape leave everything as it was" {
    var f: Fixture = .{};
    try f.init(h.loadWorkspace);
    defer f.deinit();
    const ed = &f.ed;
    _ = try openDirty(ed, "a.txt", "alpha\n", "x");

    ex(ed, "q");
    try t.expect(!f.quit());
    try t.expect(ed.pick.active);
    try t.expectEqualStrings("Quit with unsaved changes (a.txt)?", ed.pick.prompt);
    // Saving leads: Return on the question saves, as a desktop's does.
    try t.expectEqual(@as(usize, 3), ed.pick.items.items.len);
    try t.expectEqualStrings("Save all and quit", ed.pick.items.items[ed.pick.filtered.items[0]]);

    try choose(ed, "Cancel");
    try t.expect(!f.quit());
    try t.expect(!ed.pick.active);
    try t.expectEqualStrings("normal", ed.mode());
    try t.expect(try ed.buffers.active().hasUnsavedFile(ed.gpa));
    try expectOnDisk(ed, "a.txt", "alpha\n");

    // Escape (`pick.cancel`, what the picker binds it to) is Cancel.
    ex(ed, "q");
    try t.expect(ed.pick.active);
    ed.run("pick.cancel");
    try t.expect(!ed.pick.active);
    try t.expect(!f.quit());
    try t.expectEqualStrings("normal", ed.mode());
    try t.expect(try ed.buffers.active().hasUnsavedFile(ed.gpa));

    // "Quit without saving" discards.
    ex(ed, "q");
    try choose(ed, "Quit without saving");
    try t.expect(f.quit());
    try expectOnDisk(ed, "a.txt", "alpha\n");
}

test "e2e/quit: a second quit while the question is open replaces it — one question, one Escape" {
    var f: Fixture = .{};
    try f.init(h.loadWorkspace);
    defer f.deinit();
    const ed = &f.ed;
    _ = try openDirty(ed, "a.txt", "alpha\n", "x");

    // Two clicks on the window's close button: each is `app.quit`.
    ed.run("app.quit");
    ed.run("app.quit");
    try t.expect(ed.pick.active);
    try t.expectEqualStrings("Quit with unsaved changes (a.txt)?", ed.pick.prompt);
    ed.run("pick.cancel");
    try t.expect(!ed.pick.active);
    try t.expectEqualStrings("normal", ed.mode());
    try t.expect(!f.quit());
    // The displaced question's answer was stale: one "cancelled", not two
    // answers acting.
    try t.expectEqualStrings("quit cancelled", ed.echoText());
}

test "e2e/quit: \"Save all and quit\" writes every file, then quits once the saves have landed" {
    var f: Fixture = .{};
    try f.init(h.loadWorkspace);
    defer f.deinit();
    const ed = &f.ed;
    const a = try openDirty(ed, "a.txt", "alpha\n", "x");
    const b = try openDirty(ed, "b.txt", "beta\n", "y");

    ed.run("app.quit");
    try t.expectEqualStrings("Quit with unsaved changes (a.txt, b.txt)?", ed.pick.prompt);
    try choose(ed, "Save all and quit");
    ed.waitSaveOf(a);
    ed.waitSaveOf(b);
    ed.settle(2);
    try expectOnDisk(ed, "a.txt", "xalpha\n");
    try expectOnDisk(ed, "b.txt", "ybeta\n");
    try t.expect(f.quit());
}

test "e2e/quit: a save that fails does not quit, and says which file" {
    var f: Fixture = .{};
    try f.init(h.loadWorkspace);
    defer f.deinit();
    const ed = &f.ed;
    const a = try openDirty(ed, "a.txt", "alpha\n", "x");
    const b = try openDirty(ed, "b.txt", "beta\n", "y");
    // Where b's save writes before renaming over b.txt is a directory: its
    // write fails whoever runs the test.
    var threaded: std.Io.Threaded = .init(ed.gpa, .{});
    defer threaded.deinit();
    try std.Io.Dir.cwd().createDirPath(threaded.io(), "b.txt.weft-tmp");

    ed.run("app.quit");
    try choose(ed, "Save all and quit");
    ed.waitSaveOf(a);
    ed.waitSaveOf(b);
    ed.settle(2);
    try t.expect(!f.quit());
    try t.expect(contains(ed.echoText(), "couldn't save b.txt"));
    try expectOnDisk(ed, "a.txt", "xalpha\n");
    try expectOnDisk(ed, "b.txt", "beta\n");
    try t.expect(try ed.buffers.get(b).?.hasUnsavedFile(ed.gpa));
}

test "e2e/quit: what save-all cannot write is asked about again, by name — a scratch is never dropped quietly" {
    var f: Fixture = .{};
    try f.init(h.loadWorkspace);
    defer f.deinit();
    const ed = &f.ed;
    const a = try openDirty(ed, "a.txt", "alpha\n", "x");
    const scratch = try ed.buffers.create(ed.gpa, "*notes*");
    try ed.buffers.switchTo(ed.gpa, scratch, ed.head, ed.keymap);
    try ed.buffers.active().textEditor().?.doc.insert(ed.gpa, 0, "an idea\n");

    ed.run("app.quit");
    try t.expectEqualStrings("Quit with unsaved changes (a.txt, *notes*)?", ed.pick.prompt);
    try choose(ed, "Save all and quit");
    ed.waitSaveOf(a);
    ed.settle(2);
    try expectOnDisk(ed, "a.txt", "xalpha\n");
    // The file landed; the scratch has nowhere to go, so the quit asks again
    // about it alone — and with nothing to save, keeping on editing leads.
    try t.expect(!f.quit());
    try t.expect(ed.pick.active);
    try t.expectEqualStrings("Quit with unsaved changes (*notes*)?", ed.pick.prompt);
    try t.expectEqual(@as(usize, 2), ed.pick.items.items.len);
    try t.expectEqualStrings("Cancel", ed.pick.items.items[ed.pick.filtered.items[0]]);
    try choose(ed, "Quit without saving");
    try t.expect(f.quit());
}

test "e2e/quit: `:wa` saves every dirty file and stays" {
    var f: Fixture = .{};
    try f.init(h.loadWorkspace);
    defer f.deinit();
    const ed = &f.ed;
    const a = try openDirty(ed, "a.txt", "alpha\n", "x");
    const b = try openDirty(ed, "b.txt", "beta\n", "y");
    ex(ed, "wa");
    try t.expectEqualStrings("saving 2 files", ed.echoText());
    ed.waitSaveOf(a);
    ed.waitSaveOf(b);
    try expectOnDisk(ed, "a.txt", "xalpha\n");
    try expectOnDisk(ed, "b.txt", "ybeta\n");
    try t.expect(!f.quit());
}

test "e2e/quit: `:wq` quits once its save lands; `:wq!` quits over another file's unsaved edits" {
    {
        var f: Fixture = .{};
        try f.init(h.loadWorkspace);
        defer f.deinit();
        const a = try openDirty(&f.ed, "a.txt", "alpha\n", "x");
        ex(&f.ed, "wq");
        f.ed.waitSaveOf(a);
        f.ed.settle(2);
        try expectOnDisk(&f.ed, "a.txt", "xalpha\n");
        try t.expect(f.quit());
    }
    {
        var f: Fixture = .{};
        try f.init(h.loadWorkspace);
        defer f.deinit();
        _ = try openDirty(&f.ed, "a.txt", "alpha\n", "x");
        const b = try openDirty(&f.ed, "b.txt", "beta\n", "y");
        // Without `!`, the other file's edits are asked about.
        ex(&f.ed, "wq");
        f.ed.waitSaveOf(b);
        f.ed.settle(2);
        try t.expect(!f.quit());
        try t.expectEqualStrings("Quit with unsaved changes (a.txt)?", f.ed.pick.prompt);
        f.ed.run("pick.cancel");
        // With it, they are not.
        f.ed.press("i", "");
        f.ed.typeText("z");
        f.ed.press("Escape", "");
        ex(&f.ed, "wq!");
        f.ed.waitSaveOf(b);
        f.ed.settle(2);
        try expectOnDisk(&f.ed, "b.txt", "yzbeta\n");
        try expectOnDisk(&f.ed, "a.txt", "alpha\n");
        try t.expect(f.quit());
    }
}

test "e2e/quit: without the asking plugin, quitting over unsaved edits still refuses, and says how to quit anyway" {
    var f: Fixture = .{};
    try f.init(h.loadVim);
    defer f.deinit();
    const ed = &f.ed;
    _ = try openDirty(ed, "a.txt", "alpha\n", "x");
    ex(ed, "q");
    try t.expect(!f.quit());
    try t.expect(!ed.pick.active);
    try t.expectEqualStrings("not quitting: 1 unsaved (a.txt) — save, or Quit Without Saving", ed.echoText());
    ex(ed, "qa!");
    try t.expect(f.quit());
}
