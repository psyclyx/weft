//! Note embeds — the acceptance gates for architecture §11.8 depth 1 read
//! through the first real embed surface (doc/cwa-config-decisions.md
//! stress-test 2): a note that points at live things with `@embed weft://…`
//! lines.
//!
//! N1 renders a directory embed and a file embed and proves the typing hot
//! path never pays for them. N2 keeps them current across a refresh and
//! degrades each one to its own textual line plus a reason when the target is
//! gone — including a `commit` designation nothing here resolves, which is the
//! honest version of "the git plugin has no synchronous OID description door".
//! N3 captures where the cursor is into a note and activates it back through
//! `std.target.activate` after everything is closed.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const latency = @import("latency.zig");

const core = h.core;
const Editor = h.Editor;
const Project = h.Project;
const loadWorkspace = h.loadWorkspace;

const layer_name = "notes.embeds";

/// The embed feed the note entry hosts, or null when this plugin has taken
/// its paint away.
fn feed(ed: *Editor) ?*core.layers.Layer {
    return ed.session.system.caps.layers.find(ed.ctx.document() orelse return null, layer_name);
}

/// The body published for the `i`-th embed, in note order.
fn bodyOf(ed: *Editor, i: usize) []const u8 {
    const l = feed(ed) orelse return "";
    if (i >= l.spanCount()) return "";
    return l.resolvedSpan(i).message;
}

fn embedCount(ed: *Editor) usize {
    const l = feed(ed) orelse return 0;
    return l.spanCount();
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Write the fixture tree: a directory an embed lists, a file an embed
/// previews, and the note itself.
fn seed(proj: *Project, gpa: std.mem.Allocator, note: []const u8) !void {
    for ([_][]const u8{
        "mkdir -p tree && printf 'a\\n' > tree/alpha.txt && printf 'b\\n' > tree/beta.txt",
        "printf '# readme\\nsecond line\\nthird line\\n' > readme.md",
        note,
    }) |cmd| gpa.free(try proj.oracle(cmd));
}

// ── GATE N1: both embeds render, and typing does not pay for them ──

test "e2e/notes: a note's directory and file embeds render, and typing never pays for them" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    try seed(&proj, gpa, "printf '# journal\\n@embed weft://here/dir/tree?rows=3\\n@embed weft://here/file/readme.md?lines=2\\nend\\n' > journal.md");
    gpa.free(try proj.oracle("printf 'plain note\\nno embeds here\\nend\\n' > plain.md"));

    // Opening the note is the whole interaction: activation drives the round,
    // so nothing in the note says "resolve me".
    ed.runStr("open", "journal.md");
    ed.settle(6);
    try t.expectEqual(@as(usize, 2), embedCount(&ed));
    const listing = bodyOf(&ed, 0);
    try t.expect(has(listing, "tree:"));
    try t.expect(has(listing, "alpha.txt"));
    try t.expect(has(listing, "beta.txt"));
    const preview = bodyOf(&ed, 1);
    try t.expect(has(preview, "readme.md:"));
    try t.expect(has(preview, "# readme"));
    try t.expect(has(preview, "second line"));
    // `lines=2` was honored, not ignored.
    try t.expect(!has(preview, "third line"));

    // The feed is revision-stamped: one edit drops the whole set rather than
    // rebasing it onto a guess, and nothing re-resolves on the keystroke.
    ed.press("i", "");
    ed.press("x", "x");
    ed.press("Escape", "");
    try t.expectEqual(@as(usize, 0), embedCount(&ed));
    ed.run("notes-embeds");
    try t.expectEqual(@as(usize, 2), embedCount(&ed));

    // Typing latency: the note with two live embeds against an equivalent
    // note with none, in the same editor. Same shape of budget the dispatch
    // instrument uses (2x plus a floor for this box's jitter), because the
    // claim is "unaffected", not "identical".
    const plain = try typingMedian(&ed, "plain.md");
    const embedded = try typingMedian(&ed, "journal.md");
    try t.expect(embedded <= 2 * plain + 50 * std.time.ns_per_us);
}

/// Median keystroke dispatch time while `path` is the focused entry, with its
/// embed round republished before every run.
fn typingMedian(ed: *Editor, path: []const u8) !u64 {
    const runs = 5;
    const iters = 20;
    var samples: [iters]u64 = undefined;
    var medians: [runs]u64 = undefined;
    ed.runStr("open", path);
    ed.settle(6);
    for (&medians) |*m| {
        ed.press("Escape", "");
        ed.run("notes-embeds");
        ed.press("o", "");
        for (&samples) |*s| s.* = ed.pressTimed("x", "x");
        m.* = latency.statsOf(&samples).median_ns;
    }
    return latency.statsOf(&medians).median_ns;
}

// ── GATE N2: current across a refresh, and honest when it cannot resolve ──

test "e2e/notes: embeds stay current across a refresh and degrade to their line plus a reason" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    try seed(&proj, gpa, "printf '@embed weft://here/dir/tree?rows=4\\n@embed weft://here/file/readme.md\\n@embed weft://here/commit/deadbeefcafe\\n' > journal.md");

    ed.runStr("open", "journal.md");
    ed.settle(6);
    try t.expectEqual(@as(usize, 3), embedCount(&ed));
    try t.expect(!has(bodyOf(&ed, 0), "gamma.txt"));

    // A commit OID is a durable designation this build resolves through
    // nobody: it degrades, and says which half is missing (§15.19).
    try t.expect(has(bodyOf(&ed, 2), "unresolved:"));
    try t.expect(has(bodyOf(&ed, 2), "commit"));

    // The world moves under the note.
    gpa.free(try proj.oracle("printf 'g\\n' > tree/gamma.txt"));
    ed.run("notes-embeds");
    try t.expect(has(bodyOf(&ed, 0), "gamma.txt"));

    // The world goes away. Each embed degrades on its own — the note still
    // reads as itself, and the host presentation never failed.
    gpa.free(try proj.oracle("rm -rf tree readme.md"));
    ed.run("notes-embeds");
    try t.expectEqual(@as(usize, 3), embedCount(&ed));
    try t.expect(has(bodyOf(&ed, 0), "unresolved:"));
    try t.expect(has(bodyOf(&ed, 0), "no such directory"));
    try t.expect(has(bodyOf(&ed, 1), "unresolved:"));
    try t.expect(has(bodyOf(&ed, 1), "no such file"));

    // The storage form is the fallback form: the designations are still in
    // the note, untouched by anything the embed machinery did.
    const text = try ed.textAlloc();
    defer gpa.free(text);
    try t.expect(has(text, "@embed weft://here/dir/tree?rows=4"));
    try t.expect(has(text, "@embed weft://here/file/readme.md"));
}

// ── GATE N3: a captured location round-trips ──

test "e2e/notes: a captured location round-trips through the note and back" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    gpa.free(try proj.oracle("printf 'one\\ntwo\\nthree\\nfour\\n' > main.zig"));

    ed.runStr("open", "main.zig");
    ed.settle(4);
    ed.chord("j j w");
    const captured = ed.buffers.active().textEditor().?.cursorOffset();
    try t.expect(captured > 0);
    ed.runStr("notes-capture-here", "journal.md");
    ed.settle(2);

    // Close everything the capture knew about: the round trip must survive on
    // the note's bytes alone.
    ed.run("buffer-close");
    ed.settle(2);
    try t.expect(!std.mem.endsWith(u8, ed.bufferName(), "main.zig"));

    ed.runStr("notes-open", "journal.md");
    ed.settle(6);
    const note = try ed.textAlloc();
    defer gpa.free(note);
    try t.expect(has(note, "@embed weft://here/file/main.zig?at="));

    // The embed is the note's first line; `Return` is `std.target.activate`,
    // and notes is what answers it here.
    ed.chord("g g");
    ed.press("Return", "");
    ed.settle(4);
    try t.expect(std.mem.endsWith(u8, ed.bufferName(), "main.zig"));
    try t.expectEqual(captured, ed.buffers.active().textEditor().?.cursorOffset());
}
