//! e2e — the pointer, driven as a person drives it: raw button and wheel
//! facts through the platform's gesture reducer, into the one dispatch path
//! as pointer keyspecs, acting through whatever `config/defaults.js` (or a
//! config) binds. Nothing here calls a pointer command directly: if a click
//! does the right thing it is because a binding said so.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const semantic_model = h.semantic_model;
const view_runtime = h.view_runtime;
const window_layout = h.window_layout;

const Editor = h.Editor;
const Project = h.Project;
const App = h.App;

fn activeEditor(ed: *Editor) *core.Editor {
    return ed.buffers.active().textEditor().?;
}

fn openFile(ed: *Editor, name: []const u8, body: []const u8) !void {
    try core.file.writeBytes(ed.gpa, name, body);
    ed.runStr("file.open", name);
    ed.applyWindow();
}

test "e2e/pointer: under config.js a click places the caret and a drag selects" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "click.txt", "alpha beta gamma\nsecond line here\nthird line\n");

    ed.click(ed.pointAt(12).?); // the `g` of gamma
    try t.expectEqual(@as(usize, 12), activeEditor(ed).cursorOffset());
    try t.expect(activeEditor(ed).selectedRange() == null);
    // The facts rode along: a single primary click over text, in the focused pane.
    const g = ed.head.pointer;
    try t.expectEqual(@as(u8, 1), g.button);
    try t.expectEqual(@as(u8, 1), g.clicks);
    try t.expectEqual(@as(?usize, 12), g.origin.offset);
    try t.expect(g.origin.focused);
    try t.expectEqualStrings("normal", ed.mode()); // a click is not a mode change

    // A drag from `beta` into the second line selects exactly that span.
    const from = ed.pointAt(6).?;
    const to = ed.pointAt(24).?;
    ed.gestures.warp(from[0], from[1]);
    ed.pointer_ms += 5000;
    ed.pointerButton(1, true, .{});
    try t.expectEqual(@as(usize, 6), activeEditor(ed).cursorOffset());
    ed.pointerMove(to, .{});
    ed.pointerButton(1, false, .{});
    const sel = activeEditor(ed).selectedRange() orelse return error.DragSelectedNothing;
    try t.expectEqual(@as(usize, 6), sel.start);
    try t.expectEqual(@as(usize, 24), sel.end);

    // A shift-click extends the selection to the new point.
    ed.clickWith(ed.pointAt(30).?, 1, .{ .shift = true });
    const ext = activeEditor(ed).selectedRange() orelse return error.ShiftClickDroppedTheSelection;
    try t.expectEqual(@as(usize, 6), ext.start);
    try t.expectEqual(@as(usize, 30), ext.end);

    // And a plain click collapses it again.
    ed.click(ed.pointAt(2).?);
    try t.expect(activeEditor(ed).selectedRange() == null);
    try t.expectEqual(@as(usize, 2), activeEditor(ed).cursorOffset());
}

/// A test grammar's double-click: select the word under the pointer, read
/// from the pointer FACTS on the command context — the offset the shell
/// hit-tested, not a position this command works out itself.
fn cSelectWord(ctx: *core.command.Context, args: struct {}) anyerror!core.command.Value {
    _ = args;
    const off = ctx.head.pointer.hit.offset orelse return .nil;
    const ed = ctx.buffers.active().textEditor() orelse return .nil;
    const text = try ed.text().toOwnedSlice(ctx.gpa);
    defer ctx.gpa.free(text);
    const word = struct {
        fn is(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '_';
        }
    }.is;
    var start = off;
    while (start > 0 and word(text[start - 1])) start -= 1;
    var end = off;
    while (end < text.len and word(text[end])) end += 1;
    ed.placeCursor(start);
    try ed.setMark(ctx.gpa);
    ed.placeCursor(end);
    return .nil;
}

test "e2e/pointer: a double click is its own key — bound here to select a word" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "words.txt", "alpha beta gamma\n");

    _ = try ed.commands.bind(gpa, "test-select-word", core.command.define("test-select-word", "Select the word under the pointer.", cSelectWord));
    try ed.keymap.bind(gpa, core.Keymap.global_mode, "double-mouse-1", "test-select-word", core.Keymap.prio_config, "test");

    const at = ed.pointAt(13).?; // inside `gamma`
    ed.click(at);
    try t.expect(activeEditor(ed).selectedRange() == null); // one click: just the caret
    ed.clickAgain(at);
    try t.expectEqual(@as(u8, 2), ed.head.pointer.clicks);
    const sel = activeEditor(ed).selectedRange() orelse return error.DoubleClickSelectedNothing;
    try t.expectEqual(@as(usize, 11), sel.start);
    try t.expectEqual(@as(usize, 16), sel.end);

    // The third quick click is `triple-mouse-1`, which defaults.js leaves
    // on `pointer.click`: the caret goes back to the point.
    ed.clickAgain(at);
    try t.expectEqual(@as(u8, 3), ed.head.pointer.clicks);
    try t.expect(activeEditor(ed).selectedRange() == null);
    try t.expectEqual(@as(usize, 13), activeEditor(ed).cursorOffset());
}

test "e2e/pointer: the wheel scrolls the pane under it, carrying the caret into view" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (0..300) |i| try body.print(gpa, "line {d}\n", .{i});
    try openFile(ed, "long.txt", body.items);
    const view = try ed.ensureView();
    try t.expectEqual(@as(usize, 0), view.top_row);

    const over = ed.pointAt(0).?;
    ed.wheel(over, 2); // two notches toward the end
    try t.expectEqual(@as(usize, 2 * core.pointer.wheel_lines), view.top_row);
    // The caret was above the new view; it moved to the first visible row
    // rather than dragging the view back to it.
    const rope = activeEditor(ed).text();
    try t.expectEqual(view.top_row, rope.offsetToPoint(activeEditor(ed).cursorOffset()).row);

    ed.wheel(over, -1);
    try t.expectEqual(@as(usize, core.pointer.wheel_lines), view.top_row);
}

test "e2e/pointer: a click in an unfocused pane focuses it and acts there" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try openFile(ed, "left.txt", "left pane text\n");
    const left_entry = ed.buffers.active_id;
    ed.run("window.split-right");
    ed.applyWindow();
    try openFile(ed, "right.txt", "right pane text\n");
    try t.expectEqual(@as(usize, 2), ed.paneCount());
    const right_entry = ed.buffers.active_id;
    try t.expect(right_entry != left_entry);

    // Find the pane that is NOT focused, from the last frame's geometry.
    const view = try ed.ensureView();
    const focused = window_layout.headFocus(ed.win_layout, ed.head);
    var other: ?u32 = null;
    for (view.pane_maps[0..view.pane_map_count]) |m| {
        if (m.pane != focused.pane().id) other = m.pane;
    }
    const pane = other orelse return error.NoUnfocusedPane;

    ed.click(ed.pointAtIn(pane, 5).?);
    // One click: the pane took focus AND the caret landed where it pointed.
    try t.expectEqual(pane, window_layout.headFocus(ed.win_layout, ed.head).pane().id);
    try t.expectEqual(left_entry, ed.buffers.active_id);
    try t.expectEqual(@as(usize, 5), activeEditor(ed).cursorOffset());
}

test "e2e/pointer: a config rebinds mouse-1, and its command reads the click through weft.pointer()" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "rebind.txt", "0123456789\n");

    // A JS command reads the pointer facts through the plugin door and acts
    // on them: here, it lands the caret one past the click per button.
    try ed.loadJs("ptest",
        \\weft.command("ptest.click", function () {
        \\  var p = weft.pointer();
        \\  if (p === null || p.offset === null || p.kind !== "press") return;
        \\  weft.jump(p.offset + p.button + p.clicks + (p.focused ? 1 : 0));
        \\});
    );
    try core.quickjs.evalConfig(&ed.engine, ed.ctx, null, &ed.config_kv, null, "weft.bind(\"global\", \"mouse-1\", \"ptest.click\");");

    ed.click(ed.pointAt(3).?);
    // 3 + button 1 + one click + focused: the config's meaning, not the default's.
    try t.expectEqual(@as(usize, 6), activeEditor(ed).cursorOffset());
}

/// A provider for the action-node test: counts what it is asked to run.
const PingProvider = struct {
    count: usize = 0,
    subject: ?semantic_model.scene.NodeId = null,

    pub fn invoke(self: *PingProvider, request: semantic_model.action.Request) view_runtime.action.ProviderError!semantic_model.action.Outcome {
        if (!std.mem.eql(u8, request.action, "test.ping")) return .declined;
        self.count += 1;
        self.subject = request.subject;
        return .handled;
    }
};

test "e2e/pointer: a scene action node runs its action by click and by key, through one reference" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);
    try core.quickjs.evalConfig(&ed.engine, ed.ctx, null, &ed.config_kv, config_dir, "weft.use(\"defaults\");");

    const services = ed.ctx.semantic.?;
    const owner = try services.acquireOwner();
    var provider: PingProvider = .{};
    try services.registerActionProvider(gpa, owner, .init(&provider));
    const ping: semantic_model.scene.NodeId = @enumFromInt(3);
    const children = [_]semantic_model.scene.Node{
        .{ .id = @enumFromInt(2), .content = .{ .label = "a toolbar" } },
        .{ .id = ping, .focusable = true, .content = .{ .action = .{ .action = "test.ping", .label = "Ping" } } },
        .{ .id = @enumFromInt(4), .focusable = true, .content = .{ .label = "not an action" } },
    };
    const view = try services.publishView(gpa, owner, null, 1, .{
        .id = @enumFromInt(1),
        .content = .{ .container = .{ .children = &children } },
    });
    _ = try services.focusView(ed.head, gpa, view, @enumFromInt(4));
    ed.applyWindow();

    // Click: mouse-1 over the action node focuses it and runs its action.
    ed.click(ed.pointAtNode(ping) orelse return error.ActionNodeNotDrawn);
    try t.expectEqual(@as(usize, 1), provider.count);
    try t.expectEqual(@as(?semantic_model.scene.NodeId, ping), provider.subject);
    try t.expectEqual(ping, ed.head.scene_selection.path().?.leaf().?);

    // Key: the focused action node offers `std.target.activate`, routed to
    // the same action. The key names only the intention.
    try ed.keymap.bind(gpa, core.Keymap.global_mode, "F5", "std.target.activate", core.Keymap.prio_config, "test");
    ed.press("F5", "");
    try t.expectEqual(@as(usize, 2), provider.count);

    // A click on a node that is not an action only focuses it.
    ed.click(ed.pointAtNode(@enumFromInt(4)) orelse return error.RowNotDrawn);
    try t.expectEqual(@as(usize, 2), provider.count);
    try t.expectEqual(@as(semantic_model.scene.NodeId, @enumFromInt(4)), ed.head.scene_selection.path().?.leaf().?);
}
