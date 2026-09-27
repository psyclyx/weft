//! e2e test file — snapshot frames (doc/model.md §2.7): a frame is a pure
//! function of a workspace snapshot at one version, plugins answer for a
//! version off the frame path, and an answering plugin that acts cannot tear
//! the frame it was asked for.
//!
//! Driven through the real `Application` wake and the real `FrameBuilder`,
//! with host-side providers bound on the status slot the same way a plugin's
//! `wl_slot_bind` binds one (a `schema_provider`, answered through
//! `SlotHost.push`).

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const lang = @import("language_support.zig");

const core = h.core;
const Editor = h.Editor;
const frame_builder = h.app.frame_builder;

/// One application wake at the harness geometry; what it reports.
fn wake(ed: *Editor) !h.app.application.Application.AdvanceResult {
    return ed.application.advance(&ed.render, .{ .frame_start = core.task.nowNs(), .fb = .{ h.app_w, h.app_h } });
}

/// A status provider that says which revision of the active entry it was
/// asked at (as a clickable segment, `probe <rev>`, so a test can find it in
/// the frame's chrome), counts its answers, and — when told to — edits the
/// entry from inside its first answer.
const Probe = struct {
    ed: *Editor,
    act: bool = false,
    answers: usize = 0,

    fn register(self: *Probe) !void {
        try self.ed.ctx.slot_host.?.register(.{ .slot = core.status_segment.slot_name, .owner = "probe", .data = self, .handler = answer });
    }

    fn answer(data: ?*anyopaque, host: *core.slot.SlotHost, req: *const core.slot.Request) anyerror!void {
        const self: *Probe = @ptrCast(@alignCast(data.?));
        self.answers += 1;
        const te = self.ed.buffers.active().textEditor().?;
        if (self.act and self.answers == 1) {
            // Acting while answering: an edit, from inside the answer.
            const saved = te.cursorOffset();
            te.moveTo(0);
            try te.insertText(self.ed.gpa, "ACT ");
            te.moveTo(saved + 4);
        }
        var buf: [32]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "probe {d}", .{@intFromEnum(te.doc.revision())});
        const tell = try core.status_segment.encodeTell(self.ed.gpa, &.{.{ .text = "probe", .command = cmd }});
        defer self.ed.gpa.free(tell);
        try host.push(req.session, .{ .owner = "probe" }, tell);
    }
};

fn revision(ed: *Editor) u64 {
    return @intFromEnum(ed.buffers.active().textEditor().?.doc.revision());
}

fn showsProbe(ed: *Editor, rev: u64) bool {
    var buf: [32]u8 = undefined;
    return ed.pointAtStatusCommand(std.fmt.bufPrint(&buf, "probe {d}", .{rev}) catch return false) != null;
}

test "e2e/snapshot-frames: drawing one frame input twice draws the same frame, whatever the document did since" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    const te = ed.buffers.active().textEditor().?;
    try te.insertText(gpa, "alpha beta\ngamma delta\nepsilon\n");
    try te.setSelections(gpa, &.{ .{ .anchor = 0, .head = 5 }, .{ .anchor = 12, .head = 17 } }, 1);
    const diags = try ed.caps.layers.claim(gpa, &te.doc, "diagnostics", .host, "test");
    try diags.publishSpans(gpa, &.{.{ .start = 6, .end = 10, .kind = 1, .message = "unused" }});
    var probe: Probe = .{ .ed = &ed };
    try probe.register();
    _ = try wake(&ed);
    _ = try wake(&ed); // the probe's answer, drawn

    const fb = &ed.render.fb;
    const fx = &ed.application.driver.ctx;
    const prepared = try ed.application.prepare();
    const act: h.app.frame.Active = .{
        .editor = prepared.editor,
        .abuf = prepared.buffer,
        .attach = prepared.attach,
        .frame_start = core.task.nowNs(),
        .fb = .{ h.app_w, h.app_h },
        .blink_on = true,
        .menu_shown = false,
    };
    var input: frame_builder.FrameInput = .init(gpa);
    defer input.deinit();
    try fb.capture(fx, act, &input);

    var tops: [1]usize = undefined;
    try fb.draw(&input, tops[0..input.panes.items.len]);
    const first = try gpa.dupe(h.scene.DrawItem, fb.built_panes.items[0].items);
    defer gpa.free(first);

    // The document moves on: an edit shifts every anchor the frame read
    // (selections, the diagnostic) and a republish frees the old spans.
    te.moveTo(0);
    try te.insertText(gpa, "INSERTED ");
    try diags.publishSpans(gpa, &.{.{ .start = 0, .end = 3, .kind = 2, .message = "other" }});

    try fb.draw(&input, tops[0..input.panes.items.len]);
    try t.expectEqualDeep(first, fb.built_panes.items[0].items);
}

test "e2e/snapshot-frames: a provider's answer for version v shows by the frame after v" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    const te = ed.buffers.active().textEditor().?;
    try te.insertText(gpa, "one\n");
    var probe: Probe = .{ .ed = &ed };
    try probe.register();

    // The first frame has no answer and asks after it is drawn; the answer
    // lands in the same wake, and says the next frame is due.
    ed.application.damage();
    const asked = try wake(&ed);
    try t.expect(asked.redraw);
    const v0 = revision(&ed);
    try t.expect(!showsProbe(&ed, v0));
    const shown = try wake(&ed);
    try t.expect(showsProbe(&ed, v0));
    // A frame with nothing new to ask asks nothing: no loop of redraws.
    try t.expect(!shown.redraw);

    // An edit is version v1. Its first frame draws the answer it has — v0's,
    // one version behind — and asks; the next draws v1's.
    try te.insertText(gpa, "two\n");
    const v1 = revision(&ed);
    const behind = try wake(&ed);
    try t.expect(showsProbe(&ed, v0));
    try t.expect(behind.redraw);
    _ = try wake(&ed);
    try t.expect(showsProbe(&ed, v1));
    try t.expectEqual(@as(usize, 2), probe.answers);
}

test "e2e/snapshot-frames: a provider that edits while answering cannot tear the frame it answered for" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    const te = ed.buffers.active().textEditor().?;
    try te.insertText(gpa, "hello");
    var probe: Probe = .{ .ed = &ed, .act = true };
    try probe.register();

    // Frame v: drawn from "hello". The provider is asked after it, and edits.
    ed.application.damage();
    _ = try wake(&ed);
    try t.expectEqual(@as(usize, 1), probe.answers);
    try t.expectEqual(@as(usize, 9), te.text().byteLen()); // "ACT hello": the edit landed
    const view = try ed.ensureView();
    // …and the frame already drawn is v's, whole: its one line is the five
    // bytes of "hello", not a mix of the text before and the text after.
    try t.expectEqual(@as(usize, 1), view.frame_layout.lines.len);
    try t.expectEqual(@as(usize, 5), view.frame_layout.lines[0].src.end);

    // Frame v+1 reflects the edit, and the answer the edit made stale is
    // asked again for the version it made.
    _ = try wake(&ed);
    try t.expectEqual(@as(usize, 9), view.frame_layout.lines[0].src.end);
    _ = try wake(&ed);
    try t.expect(showsProbe(&ed, revision(&ed)));
}

test "e2e/snapshot-frames: an unchanged frame repaints no highlight; an edit repaints its window once" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    h.authorFile(ed, "cache.zig", "const std = @import(\"std\");\npub fn main() void {}\n");
    const syn = lang.attachedSyntax(ed) orelse return error.SyntaxDidNotAttach;
    try t.expect(lang.waitForTree(ed, syn));
    ed.settle(2);
    gpa.free(try ed.renderComposite());
    try t.expect(lang.shownHighlighted(ed));
    const painted = syn.paints;

    // A redraw that changed nothing the text shows: the same tree, the same
    // window — no query.
    gpa.free(try ed.renderComposite());
    gpa.free(try ed.renderComposite());
    try t.expectEqual(painted, syn.paints);

    // An edit reparses; the next frame paints its window once, and the one
    // after that is a hit again.
    ed.press("G", "");
    ed.press("o", "");
    ed.typeText("x");
    ed.press("Escape", "");
    gpa.free(try ed.renderComposite());
    try t.expect(syn.paints > painted);
    const after_edit = syn.paints;
    gpa.free(try ed.renderComposite());
    try t.expectEqual(after_edit, syn.paints);
    try t.expect(lang.shownHighlighted(ed));
}
