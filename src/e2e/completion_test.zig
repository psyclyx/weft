//! e2e test file — completion that pops up BY ITSELF while you type, under
//! the reference configs: the `complete` plugin's policy (word length, the
//! pause, a server's trigger characters) over core's `input.typed` signal and
//! the inline popup (`complete.show-inline`), driven through real keys.
//!
//! The pause is the plugin loop's clock, which the harness moves only when a
//! test says (`Editor.advanceClock`) — so "not yet" and "now" are exact, and
//! nothing here waits on the wall clock for a debounce.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const lang = @import("language_support.zig");

const core = h.core;
const Editor = h.Editor;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;

/// The `auto-delay` config.js and ide.js ship.
const delay_ms = 120;

/// A file holding `body`, opened, with the caret at its end in insert mode
/// (vim's `A`), under config.js.
fn appendTo(ed: *Editor, name: []const u8, body: []const u8) !void {
    try core.file.writeBytes(ed.gpa, name, body);
    ed.runStr("file.open", name);
    ed.press("A", "");
    try t.expectEqualStrings("insert", ed.mode());
}

fn expectText(ed: *Editor, want: []const u8) !void {
    const got = try ed.textAlloc();
    defer ed.gpa.free(got);
    try t.expectEqualStrings(want, got);
}

/// The inline popup is open: a pick that left the keyboard to the grammar.
fn inlineOpen(ed: *Editor) bool {
    return ed.pick.active and ed.pick.inline_keys != null;
}

/// Whether the popup offers `text` right now.
fn offers(ed: *Editor, text: []const u8) bool {
    for (ed.pick.filtered.items) |i| {
        if (std.mem.eql(u8, ed.pick.items.items[i], text)) return true;
    }
    return false;
}

test "e2e/complete-auto: a typed prefix pops the list up after the pause, and typing goes on into the buffer" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try appendTo(ed, "words.txt", "alphabet alpine beta");

    ed.typeText(" al");
    // Nothing yet: the word is long enough, but typing has not paused.
    try t.expect(!ed.pick.active);
    ed.advanceClock(delay_ms - 1);
    try t.expect(!ed.pick.active);
    ed.advanceClock(1);
    try t.expect(inlineOpen(ed));
    try t.expect(offers(ed, "alphabet") and offers(ed, "alpine"));
    // The keyboard is still vim's insert mode, and nothing is preselected.
    try t.expectEqualStrings("insert", ed.mode());
    try t.expect(ed.pick.selection() == null);

    // Typing lands in the BUFFER and narrows the list from what is there.
    ed.typeText("pi");
    try expectText(ed, "alphabet alpine beta alpi");
    try t.expect(inlineOpen(ed));
    try t.expect(offers(ed, "alpine") and !offers(ed, "alphabet"));
    // Typed out in full, the one match is what is already there: it closes.
    ed.typeText("ne");
    try expectText(ed, "alphabet alpine beta alpine");
    try t.expect(!ed.pick.active);
}

test "e2e/complete-auto: each keystroke moves the pause, and a non-word character drops it" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try appendTo(ed, "words.txt", "alphabet alpine beta");

    ed.typeText(" al");
    ed.advanceClock(delay_ms - 20);
    ed.typeText("p"); // fast typing: the pause starts over
    ed.advanceClock(delay_ms - 20);
    try t.expect(!ed.pick.active);
    ed.advanceClock(20);
    try t.expect(inlineOpen(ed));
    try t.expect(offers(ed, "alpine"));

    // A space ends the word: the popup closes and nothing is pending.
    ed.typeText(" ");
    try t.expect(!ed.pick.active);
    ed.advanceClock(10 * delay_ms);
    try t.expect(!ed.pick.active);
    // Below `auto-prefix` characters it never asks.
    ed.typeText("a");
    ed.advanceClock(10 * delay_ms);
    try t.expect(!ed.pick.active);
}

test "e2e/complete-auto: Return types a newline until a row is chosen; Tab chooses, Return accepts" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try appendTo(ed, "words.txt", "alphabet alpine beta");

    ed.typeText(" al");
    ed.advanceClock(delay_ms);
    try t.expect(inlineOpen(ed));
    // Un-navigated, Return is the buffer's: a newline, and the popup is gone
    // with the word it was about.
    ed.press("Return", "\n");
    try expectText(ed, "alphabet alpine beta al\n");
    try t.expect(!ed.pick.active);
    try t.expectEqualStrings("insert", ed.mode());

    ed.typeText("al");
    ed.advanceClock(delay_ms);
    try t.expect(inlineOpen(ed));
    // Tab moves INTO the list (the first row), not a tab into the text…
    ed.press("Tab", "\t");
    const chosen = try gpa.dupe(u8, ed.pick.selection() orelse return error.NothingChosen);
    defer gpa.free(chosen);
    try expectText(ed, "alphabet alpine beta al\nal");
    // …and now Return accepts it, replacing the typed word.
    ed.press("Return", "\n");
    try t.expect(!ed.pick.active);
    const want = try std.fmt.allocPrint(gpa, "alphabet alpine beta al\n{s}", .{chosen});
    defer gpa.free(want);
    try expectText(ed, want);
    try t.expectEqualStrings("insert", ed.mode());
}

test "e2e/complete-auto: in vim, one Escape closes the popup and leaves insert" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try appendTo(ed, "words.txt", "alphabet alpine beta");

    ed.typeText(" al");
    ed.advanceClock(delay_ms);
    try t.expect(inlineOpen(ed));
    ed.press("Escape", "");
    try t.expectEqualStrings("normal", ed.mode());
    try t.expect(!ed.pick.active);
    try expectText(ed, "alphabet alpine beta al");
}

test "e2e/complete-auto: nothing pops up in normal mode, after a paste, or with auto off" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try appendTo(ed, "words.txt", "alphabet alpine beta");

    // Typed, then insert left before the pause: the pause ends in normal mode.
    ed.typeText(" al");
    ed.press("Escape", "");
    ed.advanceClock(10 * delay_ms);
    try t.expect(!ed.pick.active);
    // Normal-mode keys are commands, never typing.
    ed.press("b", "");
    ed.press("e", "");
    ed.advanceClock(10 * delay_ms);
    try t.expect(!ed.pick.active);

    // A paste in insert mode inserts a word-prefix the caret sits after, but
    // it was not typed.
    ed.press("0", "");
    ed.chord("y i w"); // "alphabet"
    ed.press("A", "");
    ed.typeText(" ");
    ed.run("vim.paste-before");
    try t.expect(std.mem.endsWith(u8, try textTail(ed), "alphabet"));
    ed.advanceClock(10 * delay_ms);
    try t.expect(!ed.pick.active);

    // auto = off: typing never opens it, however long the pause.
    try ed.setConfig("complete", "auto", "off");
    ed.typeText(" al");
    ed.advanceClock(10 * delay_ms);
    try t.expect(!ed.pick.active);
    // …and the manual key still does.
    ed.press("C-SPC", "");
    try t.expect(ed.pick.active and ed.pick.inline_keys == null);
}

var tail_buf: [256]u8 = undefined;

/// The last bytes of the active document (a scratch copy).
fn textTail(ed: *Editor) ![]const u8 {
    const all = try ed.textAlloc();
    defer ed.gpa.free(all);
    const n = @min(all.len, tail_buf.len);
    @memcpy(tail_buf[0..n], all[all.len - n ..]);
    return tail_buf[0..n];
}

/// A weft booted from the real config/ide.js in a throwaway project.
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
        try self.ed.buffers.setDefaultMode(gpa, self.ed.head.currentMode());
    }

    fn deinit(self: *IdeApp) void {
        self.loader.deinit();
        self.ed.deinit();
        self.proj.deinit();
    }
};

test "e2e/complete-auto: ide.js — Escape closes the popup and the editor keeps the keys" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try core.file.writeBytes(gpa, "words.txt", "alphabet alpine beta\n");
    ed.runStr("file.open", "words.txt");
    try t.expectEqualStrings("ide", ed.mode());
    ed.press("C-End", "");

    ed.typeText("al");
    ed.advanceClock(delay_ms);
    try t.expect(inlineOpen(ed));
    ed.press("Escape", "");
    try t.expect(!ed.pick.active);
    try t.expectEqualStrings("ide", ed.mode());
    // Typing carries on where it was.
    ed.typeText("x");
    try expectText(ed, "alphabet alpine beta\nalx");
}

test "e2e/complete-auto: a language server's trigger character pops it up at once" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    const peer = try lang.Peer.init(gpa, "trig");
    defer peer.deinit(gpa);
    try ed.setConfig("lsp", "zig", peer.command);
    try core.file.writeBytes(gpa, "trig.zig", "const std = @import(\"std\");\nfn f() void {\n    std\n}\n");
    ed.runStr("file.open", "trig.zig");
    var mbuf: [64]u8 = undefined;
    var cmd: [256]u8 = undefined;
    try t.expect(h.drainUntilOracle(&app.proj, ed, try std.fmt.bufPrint(&cmd, "test -s {s} && echo yes", .{peer.marker(&mbuf, "init")}), "yes"));
    // The server said `.` opens completion; the lsp plugin publishes that on
    // the entry once the handshake lands.
    try t.expect(awaitTriggers(ed));

    // After `std` on line three, a `.`: no word yet and no pause — the list
    // opens on the next wake, with the server's answer in it.
    const text = try ed.textAlloc();
    defer gpa.free(text);
    const std_end = std.mem.lastIndexOf(u8, text, "std\n").? + "std".len;
    ed.buffers.active().textEditor().?.placeCursor(std_end);
    ed.press("i", "");
    try t.expectEqualStrings("insert", ed.mode());
    ed.typeText(".");
    ed.advanceClock(0);
    var item_buf: [64]u8 = undefined;
    const item = peer.item(&item_buf);
    const deadline = core.task.nowNs() + 5 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline and !(inlineOpen(ed) and offers(ed, item))) ed.settle(2);
    try t.expect(inlineOpen(ed));
    try t.expect(offers(ed, item));
}

/// Settle until the active entry carries the server's trigger characters.
fn awaitTriggers(ed: *Editor) bool {
    const deadline = core.task.nowNs() + 5 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        ed.settle(2);
        if (core.intent.factsFor(ed.ctx).get("lsp.trigger-characters")) |v| {
            if (std.mem.indexOfScalar(u8, v, '.') != null) return true;
        }
    }
    return false;
}
