//! e2e test file — documentation popups (doc/docs-popups.md): a hover and
//! a signature's help are markdown documents the `lsp` plugin hands a caret
//! surface (`wl_surface_doc`), which core renders through the markdown
//! pipeline every markdown entry uses, soft-wrapped to the popup. When each
//! opens and closes is the plugin's, over `input.typed`, `input.caret` and
//! `input.mode`. Driven against the scripted peer (`language_support.Peer`),
//! so nothing here depends on a real server.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const lang = @import("language_support.zig");

const core = h.core;
const Editor = h.Editor;

/// The plugin surface showing a document, if one is.
fn docSurface(ed: *Editor) ?*core.surface.Surface {
    for (ed.plugins.items) |pl| {
        if (pl.surface.active and pl.surface.placement == .caret and pl.surface.info.len > 0) return &pl.surface;
    }
    return null;
}

/// Settle until a document popup holding `needle` shows, or fail.
fn awaitDoc(ed: *Editor, needle: []const u8) !*core.surface.Surface {
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        ed.settle(2);
        if (docSurface(ed)) |s| if (std.mem.indexOf(u8, s.info, needle) != null) return s;
    }
    return error.DocNeverShown;
}

fn openWithPeer(app: *h.App, peer: lang.Peer, body: []const u8) !void {
    const ed = &app.ed;
    try ed.setConfig("lsp", "zig", peer.command);
    try core.file.writeBytes(ed.gpa, "doc.zig", body);
    ed.runStr("file.open", "doc.zig");
    var mbuf: [64]u8 = undefined;
    var cmd: [256]u8 = undefined;
    try t.expect(h.drainUntilOracle(&app.proj, ed, try std.fmt.bufPrint(&cmd, "test -s {s} && echo yes", .{peer.marker(&mbuf, "init")}), "yes"));
}

test "e2e/docs-popup: a hover is the server's markdown, rendered and wrapped inside the window, and goes when the caret moves" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    const peer = try lang.Peer.init(gpa, "hov");
    defer peer.deinit(gpa);
    try openWithPeer(&app, peer, "const a = 1;\nconst b = 2;\n");

    ed.buffers.active().textEditor().?.placeCursor(6);
    try t.expect(h.drainSurfaceText(ed, "lsp.hover", "hermetic hover"));
    const surf = docSurface(ed) orelse return error.NoPopup;
    // A document, not rows of text: the host renders the markdown.
    try t.expectEqual(@as(usize, 0), surf.rows.items.len);
    try t.expect(std.mem.indexOf(u8, surf.info, "```zig") != null);

    // Laid out: inside the window, the long paragraph wrapped onto several
    // lines, the code fence's markers taking no line of their own.
    const pixels = try ed.renderComposite();
    gpa.free(pixels);
    const v = try ed.ensureView();
    const body: h.region.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(h.app_w), .h = @floatFromInt(h.app_h) };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cl = (try h.view.popup.layoutCaretSurface(v, arena.allocator(), surf, body)) orelse return error.NoLayout;
    const info = cl.info orelse return error.NoDoc;
    try t.expect(info.x >= body.x and info.x + info.w <= body.x + body.w);
    // signature + paragraph (wrapped: 2+) + paragraph, spacing aside.
    try t.expect(info.lines >= 4);

    // The caret moves: the hover goes.
    ed.buffers.active().textEditor().?.placeCursor(14);
    ed.settle(3);
    try t.expect(docSurface(ed) == null);
}

test "e2e/docs-popup: typing a call opens its signature's help above the caret, the active parameter and its docs in it; leaving insert closes it" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    const peer = try lang.Peer.init(gpa, "sig");
    defer peer.deinit(gpa);
    try openWithPeer(&app, peer, "fn f() void {\n    \n}\n");

    // Into the empty line, typing a call: `(` is the server's trigger.
    const text = try ed.textAlloc();
    defer gpa.free(text);
    ed.buffers.active().textEditor().?.placeCursor(std.mem.indexOf(u8, text, "    \n").? + 4);
    ed.press("i", "");
    ed.typeText("hermetic(1, ");
    const surf = try awaitDoc(ed, "hermetic(first: u8, count: usize) void");
    try t.expect(surf.above);
    // The active parameter, what it is for, and the function's docs.
    try t.expect(std.mem.indexOf(u8, surf.info, "count: usize") != null);
    try t.expect(std.mem.indexOf(u8, surf.info, "How many times.") != null);
    try t.expect(std.mem.indexOf(u8, surf.info, "Hermetic signature docs.") != null);

    // Escape: insert is left, and the help with it.
    ed.press("Escape", "");
    ed.settle(3);
    try t.expect(docSurface(ed) == null);
}

const completionPopup = h.completionPopup;

test "e2e/docs-popup: a chosen completion shows its docs beside the list — its detail as code, then its documentation — and accepting puts it in place of the word" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    const peer = try lang.Peer.init(gpa, "cdoc");
    defer peer.deinit(gpa);
    try openWithPeer(&app, peer, "fn f() void {\n    her\n}\n");

    const text = try ed.textAlloc();
    defer gpa.free(text);
    ed.buffers.active().textEditor().?.placeCursor(std.mem.indexOf(u8, text, "her\n").? + 3);
    ed.press("i", "");
    var item_buf: [64]u8 = undefined;
    const item = peer.item(&item_buf);
    // The race at the caret; the server's answer lands off a later poll.
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        ed.press("C-SPC", "");
        ed.settle(3);
        const s = completionPopup(ed) orelse continue;
        if (std.mem.indexOf(u8, h.completionLabel(s.rows.items[0]) orelse "", "hermetic") != null) break;
    }
    // Asked for, the list opens with its first row chosen — and the chosen
    // row's docs are the popup's document.
    const chosen = completionPopup(ed) orelse return error.NoList;
    try t.expectEqual(@as(?usize, 0), chosen.selected);
    try t.expect(std.mem.indexOf(u8, chosen.info, "```\nfn hermetic_detail(n: usize) void\n```") != null);
    try t.expect(std.mem.indexOf(u8, chosen.info, "Hermetic completion **docs**.") != null);

    // Return accepts: the word is the item, and the list is gone.
    ed.press("Return", "\n");
    ed.settle(2);
    try t.expect(completionPopup(ed) == null);
    const after = try ed.textAlloc();
    defer gpa.free(after);
    try t.expect(std.mem.indexOf(u8, after, item) != null);
    try t.expect(std.mem.indexOf(u8, after, "\n    her\n") == null);
}

test "e2e/docs-popup: an item the server sent without docs gets them when chosen — completionItem/resolve, through the provider that answered it" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    const peer = try lang.Peer.init(gpa, "lazy");
    defer peer.deinit(gpa);
    try openWithPeer(&app, peer, "fn f() void {\n    her\n}\n");

    const text = try ed.textAlloc();
    defer gpa.free(text);
    ed.buffers.active().textEditor().?.placeCursor(std.mem.indexOf(u8, text, "her\n").? + 3);
    ed.press("i", "");
    // Asked for: the first row is chosen, and it came with no docs — so the
    // popup asks the server for them, and they land as the popup's document.
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    var found = false;
    while (core.task.nowNs() < deadline and !found) {
        if (completionPopup(ed) == null) ed.press("C-SPC", "");
        ed.settle(3);
        if (completionPopup(ed)) |s| found = std.mem.indexOf(u8, s.info, "Resolved **lazily**.") != null;
    }
    try t.expect(found);
    const s = completionPopup(ed).?;
    try t.expect(std.mem.indexOf(u8, s.info, "fn lazily_resolved() void") != null);
    try t.expectEqual(@as(?usize, 0), s.selected);
}
