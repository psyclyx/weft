//! Built-in commands. Everything user-visible goes through the command
//! ABI — these are ordinary typed functions the same `define` machinery
//! wraps, registered under the same late-binding names a config or
//! plugin may shadow. If a built-in can't live behind this door, the
//! core is wrong (the manifesto's test).

const std = @import("std");

const command = @import("command.zig");
const Editor = @import("Editor.zig");
const Context = command.Context;
const Value = command.Value;
const facts = @import("weft_facts");
const container_mod = @import("container.zig");
const Actions = @import("action.zig");
const target_open = @import("target_open.zig");
const semantic_model = @import("weft_semantic");
const placement = @import("placement.zig");
const action_here = @import("action_here.zig");
const designation = @import("designation.zig");
const scene_edit = @import("scene_edit.zig");

const ok: Value = .nil;

fn semanticFieldInput(ctx: *Context, input: @import("semantic.zig").Services.FieldInput) !bool {
    const services = ctx.semantic orelse return false;
    return services.inputFocusedField(ctx.head, ctx.gpa, input);
}

fn semanticMove(ctx: *Context, movement: @import("weft_semantic").focus.Movement) !bool {
    const services = ctx.semantic orelse return false;
    return services.moveHeadFocus(ctx.head, ctx.gpa, movement);
}

/// Invoke one action advertised by the focused semantic node.  These command
/// names are deliberately about the shared action vocabulary, not about any
/// particular tool: a directory view, a picker, or a future structured editor
/// may all advertise the same selection operation.  An ordinary text buffer
/// simply has no semantic action to consume, so the command is a harmless
/// no-op there.
fn invokeSemanticAction(ctx: *Context, action_name: []const u8) anyerror!Value {
    // ONE ACTION NAME, EITHER PLANE — `action_here` owns that rule, because the
    // guest door `wl_semantic_action` needs exactly the same one.
    if (try action_here.invokeHere(ctx, action_name, 0)) |_| return ok;
    // Neither plane: an action nobody claims is a no-op, as it always was — an
    // ordinary text buffer has no `view.apply` and says so by silence.
    const cmd = ctx.actions.resolveFacts(action_name, ctx.capturedCtx().mergedFacts()) orelse return ok;
    _ = try command.run(ctx.commands, ctx, cmd, &.{});
    return ok;
}

/// A handler that SHOWED ITS OWN BUFFER keeps the input: the scene it published
/// for the open protocol is not what your keys are about.
///
/// Left focused, both planes offer the std vocabulary for the same entry and
/// the resolver refuses the tie — correctly, because two owners really are
/// claiming one intention. One listing, one plane.
fn dropFocusIfShownAsBuffer(ctx: *Context) void {
    const entry = ctx.buffers.active();
    if (entry.projection == null) return;
    const tool = entry.tool_view orelse return;
    // ONLY THE DUPLICATE. This cleared any focus at all whenever a listing was
    // showing, which is wrong the moment the two differ: a handler that opens
    // some OTHER view and focuses it had that focus thrown away because a
    // listing happened to be the active buffer.
    const path = ctx.head.scene_selection.path() orelse return;
    if (!path.view.eql(tool)) return;
    ctx.head.scene_selection.clear();
}

/// The typed target the ROW UNDER POINT links to, when the active entry is a
/// text projection. The producer.s scene still carries each row.s link; the
/// projection just says which row you are on.
fn rowTargetHere(ctx: *Context) ?semantic_model.target.Located {
    const services = ctx.semantic orelse return null;
    const subject = rowSubjectHere(ctx) orelse return null;
    const view = services.views.get(subject.view) orelse return null;
    const node = view.node(subject.node) orelse return null;
    const link = node.target orelse return null;
    return .{ .target = link.target, .revision = link.revision, .location = .whole };
}

/// The producer view and scene node the ROW UNDER POINT stands for, when the
/// active entry is a text projection whose producer named its view.
fn rowSubjectHere(ctx: *Context) ?struct { view: semantic_model.view.Ref, node: semantic_model.scene.NodeId } {
    const view = ctx.buffers.active().tool_view orelse return null;
    const row = action_here.subjectsHere(ctx).row orelse return null;
    return .{ .view = view, .node = row };
}

/// Register a command trampoline for an open semantic action name. This is
/// the config/plugin seam for structured views: the name need not be in core
/// (or in the standard vocabulary), and the focused view decides whether it
/// advertises and handles it at invocation time.
pub fn registerSemanticAction(
    gpa: std.mem.Allocator,
    commands: *command.Commands,
    services: *@import("semantic.zig").Services,
    name: []const u8,
) !void {
    // Keep an existing command's richer compatibility behavior (for example
    // field-edit's generic-field fallback). Open names only need a trampoline
    // when no plugin/core command already owns the slot.
    if (commands.resolve(name) != null) return;
    const target = try services.declareSemanticCommand(gpa, name);
    _ = try commands.bind(gpa, name, .{
        .name = name,
        .summary = "Run the focused view's action of this name.",
        .args = &.{},
        .handler = semanticActionTrampoline,
        .data = target,
        .arity = semanticArity(name),
    });
}

/// How an open semantic action maps over several selected rows. The standard
/// vocabulary says: a transfer (copy, cut, paste) reads the whole selection as
/// one request, since it makes or consumes ONE value; any other `selection.*`
/// action and `target.open` act on each row; a `view.*` action acts on the
/// view once. Any other name says nothing, so it is refused on several rows
/// rather than run on the focused one alone.
fn semanticArity(name: []const u8) ?@import("selection.zig").Arity {
    const standard = semantic_model.action.standard;
    for ([_][]const u8{ standard.copy, standard.cut, standard.paste_before, standard.paste_after }) |transfer|
        if (std.mem.eql(u8, name, transfer)) return .whole;
    if (std.mem.startsWith(u8, name, "selection.") or std.mem.eql(u8, name, standard.open))
        return .each_extent;
    if (std.mem.startsWith(u8, name, "view.")) return .whole;
    return null;
}

fn semanticActionTrampoline(ctx: *Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const target: *@import("semantic.zig").Services.SemanticCommand = @ptrCast(@alignCast(data.?));
    // These two standard actions have useful generic fallbacks when a scene
    // publishes a target link or an editable field but its provider does not
    // need custom behavior. The action names remain the public config surface;
    // neither fallback knows which plugin authored the scene.
    if (std.mem.eql(u8, target.name, semantic_model.action.standard.open))
        return cTargetOpenFocused(ctx, .{});
    if (std.mem.eql(u8, target.name, semantic_model.action.standard.edit))
        return cFieldEdit(ctx, .{});
    return invokeSemanticAction(ctx, target.name);
}

fn cItemInsertBefore(ctx: *Context, _: struct {}) anyerror!Value {
    return invokeSemanticAction(ctx, semantic_model.action.standard.insert_before);
}

fn cItemInsertAfter(ctx: *Context, _: struct {}) anyerror!Value {
    return invokeSemanticAction(ctx, semantic_model.action.standard.insert_after);
}

fn cSelectionCopy(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return invokeSemanticAction(ctx, semantic_model.action.standard.copy);
}

fn cSelectionCut(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return invokeSemanticAction(ctx, semantic_model.action.standard.cut);
}

fn cSelectionDelete(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return invokeSemanticAction(ctx, semantic_model.action.standard.delete);
}

fn cSelectionPasteBefore(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return invokeSemanticAction(ctx, semantic_model.action.standard.paste_before);
}

fn cSelectionPasteAfter(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return invokeSemanticAction(ctx, semantic_model.action.standard.paste_after);
}

fn cTargetOpenFocused(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    const services = ctx.semantic orelse return ok;
    // The view gets first refusal: a target link describes the resource,
    // while its row may navigate locally instead of opening another entry.
    if (try action_here.invokeHere(ctx, semantic_model.action.standard.open, 0)) |effect|
        if (effect != .declined) return ok;
    const located = (try services.focusedTarget(ctx.head)) orelse rowTargetHere(ctx) orelse
        return invokeSemanticAction(ctx, semantic_model.action.standard.open);
    const result = try target_open.openLocated(services, ctx.head, ctx.gpa, located, null);
    dropFocusIfShownAsBuffer(ctx);
    // No handler renders this kind. The shell's placement policy may still
    // open it as an ordinary workspace entry (§9.4) — that is an open, not a
    // claim, so it runs only once every handler has declined.
    //
    // The outcome carries a HINT, not a pane: "the primary viewport" (§9.4,
    // doc/cwa-config-decisions.md D3). From an ordinary pane the policy reads
    // that as "here" and nothing jumps; from a docked companion it reads as
    // "the editing pane", which is the whole of "Return in the sidebar opens
    // in the editor" — stated once, in the policy, rather than by every
    // opener guessing.
    if (result == .no_handler) {
        if (ctx.entries) |entries| {
            const kind: placement.Kind = if (services.targets.get(located.target)) |d| .of(d.kind) else .unknown;
            ctx.head.placement = .{ .hint = .primary, .kind = kind };
            if (try entries.open(entries.context, ctx, located)) return ok;
            ctx.head.placement = null; // declined: never fires against a later open
        }
    }
    return targetOpenResult(result);
}

fn cHierarchyToggleExpanded(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return invokeSemanticAction(ctx, semantic_model.action.standard.toggle_expanded);
}

fn cHierarchyStepOut(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return invokeSemanticAction(ctx, semantic_model.action.standard.open_container);
}

fn cFieldEdit(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    const services = ctx.semantic orelse return ok;
    const effect = services.invokeFocusedAction(
        &ctx.head.interactions,
        ctx.head,
        ctx.gpa,
        semantic_model.action.standard.edit,
    ) catch |err| switch (err) {
        error.ActionUnavailable, error.ProviderUnavailable => null,
        error.StaleView => return ok,
        else => return err,
    };
    if (effect) |handled| switch (handled) {
        .declined => {},
        else => return ok,
    };
    // `std.editing.begin` (doc/chrome.md §5.2): edit the focused row's
    // primary field — begun under `row` granularity, where the focus was
    // the row; where it already edits (`text`), nothing changes.
    _ = scene_edit.begin(services, ctx.head, ctx.gpa) catch |err| switch (err) {
        error.ActionRefused => {
            echoLine(ctx, "this row cannot be edited now");
            return ok;
        },
        error.ReadOnly => {
            echoLine(ctx, "this field is read-only");
            return ok;
        },
        else => return err,
    };
    return ok;
}

/// Commit the begun edit (activating what is being edited): keep the text,
/// apply the view's draft when it changed.
fn cFieldEditCommit(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    const services = ctx.semantic orelse return ok;
    _ = try scene_edit.commit(services, ctx.head, ctx.gpa);
    return ok;
}

/// Cancel the begun edit, putting back the text it began from.
fn cFieldEditCancel(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    const services = ctx.semantic orelse return ok;
    _ = try scene_edit.cancel(services, ctx.head, ctx.gpa);
    return ok;
}

/// `structural-focus text|row` — the loaded grammar's DECLARATION of how it
/// focuses a row that holds a field (doc/chrome.md §5.2, `input.Granularity`).
/// A grammar says it once, like its resting postures; core reads it where a
/// focus lands and knows no grammar's name.
fn cStructuralFocus(ctx: *Context, args: struct { granularity: []const u8 }) anyerror!Value {
    const services = ctx.semantic orelse return ok;
    services.granularity = @import("weft_input").Granularity.parse(args.granularity) orelse return error.InvalidArgument;
    return ok;
}

fn cViewRefresh(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return invokeSemanticAction(ctx, semantic_model.action.standard.refresh);
}

fn cViewRevert(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return invokeSemanticAction(ctx, semantic_model.action.standard.revert);
}

fn cViewApply(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return invokeSemanticAction(ctx, semantic_model.action.standard.apply);
}

/// Swallow a refusal. The door (`Context.edit`, `Context.textEditor`) already
/// enforced it and echoed why, so a `view` peer typing — or a text op aimed at
/// an entry that holds no text — is not a command error, just a no-op. Other
/// errors propagate.
fn editErr(e: anyerror) anyerror!Value {
    if (e != error.Unauthorized) return e;
    return ok;
}

/// The text edits act at EVERY selection: `target`'s range at each (the
/// selection, or the caret / the scalar beside it), through the one gated
/// door as one commit. With a single selection this is exactly
/// `ctx.edit(ed.insertRange()/backspaceRange()/forwardRange(), bytes)`.
fn editAtSelections(ctx: *Context, ed: *Editor, target: Editor.EditTarget, bytes: []const u8) anyerror!Value {
    const ranges = try ed.editRanges(ctx.gpa, target);
    defer ctx.gpa.free(ranges);
    ctx.editEach(ranges, bytes) catch |e| return editErr(e);
    return ok;
}

fn cInsertText(ctx: *Context, args: struct { text: []const u8 }) anyerror!Value {
    if (try semanticFieldInput(ctx, .{ .commit = .from(args.text) })) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    return editAtSelections(ctx, ed, .insert, args.text);
}

fn cDeleteBackward(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticFieldInput(ctx, .delete_previous)) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    return editAtSelections(ctx, ed, .backward, "");
}

fn cDeleteForward(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticFieldInput(ctx, .delete_next)) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    return editAtSelections(ctx, ed, .forward, "");
}

/// A refused unwind reports "nothing happened" — the door already announced
/// why on the echo line.
fn undid(result: @import("undo.zig").Error!bool) anyerror!Value {
    return .{ .boolean = result catch |e| switch (e) {
        error.Unauthorized, error.OutOfLimit, error.Collapsed => false,
        else => return e,
    } };
}

fn cUndo(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    const ed = ctx.textEditor() catch return .{ .boolean = false };
    const before = ed.doc.commitCount();
    const did = ed.undo(ctx.gpa, ctx.undoGate());
    flashChanged(ctx, &ed.doc, before);
    return undid(did);
}

fn cRedo(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    const ed = ctx.textEditor() catch return .{ .boolean = false };
    const before = ed.doc.commitCount();
    const did = ed.redo(ctx.gpa, ctx.undoGate());
    flashChanged(ctx, &ed.doc, before);
    return undid(did);
}

/// Record what an undo/redo just put back as an `undo` flash. Only core sees
/// that span — the grammar that pressed the key never learns which bytes
/// came back — so core records it, and the frame shows it only where the
/// configuration asks (`editor/flash-undo`).
fn flashChanged(ctx: *Context, doc: *@import("Document.zig"), before: usize) void {
    const span = @import("flash.zig").changedSince(doc, before) orelse return;
    ctx.caps.flash.set(ctx.gpa, &ctx.caps.layers, doc, span, .undo) catch {};
}

/// The default `save` provider: write the buffer to its file backing. `save` is
/// an ACTION (not a bare command), so a projection (files/git) registers its
/// own `save` provider scoped to its tool identity — the action system picks it
/// over this in the projection's buffer, by specificity. The core stays
/// projection-agnostic: no `if (isTool)` branch lives here.
fn cSaveFile(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    try ed.requestSave(ctx.gpa);
    return ok;
}

const FieldMotionArgs = struct {};
fn fieldMotion(comptime movement: @import("field_motion.zig").Movement) fn (*Context, FieldMotionArgs) anyerror!Value {
    return struct {
        fn run(ctx: *Context, _: FieldMotionArgs) anyerror!Value {
            _ = try semanticFieldInput(ctx, .{ .motion = movement });
            return ok;
        }
    }.run;
}

fn cCursorLeft(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticFieldInput(ctx, .move_previous)) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    ed.moveLeft();
    return ok;
}

fn cCursorRight(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticFieldInput(ctx, .move_next)) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    ed.moveRight();
    return ok;
}

fn cCursorUp(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticMove(ctx, .previous)) return ok;
    if (ctx.panes) |panes| if (panes.vertical) |vertical| if (vertical(panes.context, ctx, -1)) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    ed.moveUp();
    return ok;
}

fn cCursorDown(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticMove(ctx, .next)) return ok;
    if (ctx.panes) |panes| if (panes.vertical) |vertical| if (vertical(panes.context, ctx, 1)) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    ed.moveDown();
    return ok;
}

/// Move point to the next/previous ROW of a projection, landing where that row
/// is ACTIONABLE — the start of its editable span when it has one, its own
/// start otherwise.
///
/// A listing is text, so plain `cursor.down` works on it; what plain cursor
/// motion cannot do is land you on the NAME. Column 0 of `  ▸ src` is an
/// indent, and a grammar asking "may I insert here" gets `structural` there and
/// `field` two characters along — so navigating a listing with `cursor.down`
/// leaves you somewhere you cannot type. Rows are the unit of a projection;
/// this moves in that unit.
fn moveRow(ctx: *Context, delta: enum { next, prev }) anyerror!Value {
    // A FOCUSED SCENE MOVES FIRST. The head pointing at a view is pointing at
    // it whatever buffer is underneath — and a listing being the active buffer
    // must not turn "next node" into "next row of something else".
    if (try semanticMove(ctx, if (delta == .next) .next else .previous)) return ok;
    const entry = ctx.buffers.active();
    const view = entry.projection orelse {
        // Not a projection: the ordinary line step, so one binding serves both.
        return if (delta == .next) cCursorDown(ctx, .{}) else cCursorUp(ctx, .{});
    };
    const ed = ctx.textEditor() catch |e| return editErr(e);
    // Anchored on the ROW point is in, not on point itself: from inside a row,
    // "the previous row" measured against the caret finds that row again,
    // because its own start is behind the caret.
    const here = view.subjectAt(ed.cursorOffset());
    // The ROW's start, not the part's: "the previous row" measured from inside
    // a column would find columns, and there is only ever one row step.
    const at = if (here) |s| s.node.start else ed.cursorOffset();
    var best: ?*const @import("projection.zig").Node = null;
    for (view.nodes.items) |*n| {
        if (!n.focusable) continue;
        switch (delta) {
            .next => if (n.start > at and (best == null or n.start < best.?.start)) {
                best = n;
            },
            .prev => if (n.start < at and (best == null or n.start > best.?.start)) {
                best = n;
            },
        }
    }
    const target = best orelse return ok;
    ed.placeCursor(target.restingOffset(if (here) |s| s.role else null));
    return ok;
}

fn cRowDown(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return moveRow(ctx, .next);
}

fn cRowUp(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return moveRow(ctx, .prev);
}

// Document motions return anchored ranges through the motions plugin.
// Retained fields expose navigation through standard offers above; both
// presentations share these selection commands.

fn cSetMark(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticFieldInput(ctx, .set_mark)) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    try ed.setMark(ctx.gpa);
    return ok;
}

/// The scene selection the dispatching head holds, when the entry this call
/// is about is a scene (no text of its own).
fn sceneRows(ctx: *Context) ?*@import("Head.zig").SceneSelection {
    const entry = ctx.entry() orelse return null;
    if (entry.textEditor() != null) return null;
    const scene = &ctx.head.scene_selection;
    return if (scene.head() != null) scene else null;
}

/// `selection.start-rows`: anchor a range of ROWS at the focused one, whatever part of
/// the row is focused — a listing focuses a row's name field, where
/// `selection.start` selects text in the field (vim's `v`); a linewise mark over
/// rows (vim's `V`) is this. The next move grows the range.
fn cMarkRows(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    const scene = sceneRows(ctx) orelse return ok;
    scene.anchor = scene.head();
    return ok;
}

fn cClearSelection(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    // In a scene: drop the row range this extent was growing — and any text
    // selected in the field it focuses.
    if (sceneRows(ctx)) |scene| scene.anchor = null;
    if (try semanticFieldInput(ctx, .clear_selection)) return ok;
    if (sceneRows(ctx) != null) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    ed.clearSelection();
    return ok;
}

fn cUndoBarrier(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (ctx.buffers.active().textEditor() == null) return ok;
    // Seal the open undo unit so the next edit starts a fresh one. Cursor
    // motions already barrier (Editor.moveTo); this exposes the same seam to a
    // modal plugin, which fires it on the boundaries a motion doesn't cover —
    // notably LEAVING insert (vim's `i…Esc` is one undo unit; the next command
    // must be its own, or `Esc` then `dd` then `u` reverses BOTH the typing and
    // the delete instead of just the delete).
    const ed = ctx.textEditor() catch |e| return editErr(e);
    ed.history.barrier();
    return ok;
}

fn cSetMode(ctx: *Context, args: struct { mode: []const u8 }) anyerror!Value {
    // THE POLICY DOOR (task #19 item 3): this is a bound command handler —
    // it HAS a live `*command.Context`, so it captures a `Ctx` and changes
    // mode through `Ctx.setMode`, not the raw `Head.setModeRaw` mechanism.
    try ctx.capturedCtx().setMode(args.mode);
    return ok;
}

/// The BREAK-OUT half of `capture` (§10.4). A grammar binds a chord to this
/// and keeps it bound in every state, which is what makes capture a state
/// you can always leave: it drops the entry's capture declaration, restoring
/// whatever the capture displaced, and rests the head where the restored
/// posture says. On an entry that is not capturing it does nothing — the
/// chord is pressed far more often than it applies.
fn cPostureBreakOut(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (!ctx.buffer().breakOutOfCapture()) return ok;
    const resting = ctx.buffers.restingModeFor(ctx.posture());
    if (resting.len > 0) try ctx.capturedCtx().setMode(resting);
    return ok;
}

fn cQuit(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.quit.* = true;
    return ok;
}

fn cInsertNewline(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    // Return/Tab are physical keys, not commits: a focused field consumes them
    // (nothing leaks to a backing document) and inserts nothing
    // (doc/cwa-review.md §2.2).
    if (try semanticFieldInput(ctx, .{ .commit = .none })) return ok;
    if (fieldHere(ctx)) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    return editAtSelections(ctx, ed, .insert, "\n");
}

fn cInsertTab(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticFieldInput(ctx, .{ .commit = .none })) return ok;
    if (fieldHere(ctx)) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    return editAtSelections(ctx, ed, .insert, "\t");
}

/// Is point inside a PROJECTION's editable span — a field made of text?
///
/// The same question `semanticFieldInput` asks of the scene plane, asked of the
/// other one. A row's name is a field however it is spelled: it is one line and
/// it holds a name, so a physical Return or Tab is consumed and writes nothing.
/// Without this a Tab pressed while renaming put a literal tab in the filename
/// — the exact leak `doc/cwa-review.md` §2.2 named, reopened by moving the
/// field onto the text plane.
fn fieldHere(ctx: *Context) bool {
    return ctx.buffers.active().fieldAtPoint();
}

// ── Buffers ─────────────────────────────────────────────────────────

fn cBufferNext(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.buffers.switchTo(ctx.gpa, ctx.buffers.nextId(), ctx.head, ctx.keymap);
    return ok;
}

fn cBufferPrevious(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.buffers.switchTo(ctx.gpa, ctx.buffers.prevId(), ctx.head, ctx.keymap);
    return ok;
}

/// Return to the previously active buffer — where a tool's `q` lands you (back
/// where you came from, in that buffer's own mode). Generic: the tool binds `q`
/// here; the core decides where "back" is.
fn cBufferBack(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.buffers.back(ctx.gpa, ctx.head, ctx.keymap);
    return ok;
}

fn cBufferSwitch(ctx: *Context, args: struct { id: i64 }) anyerror!Value {
    if (args.id < 0) return error.TypeMismatch;
    try ctx.buffers.switchTo(ctx.gpa, @intCast(args.id), ctx.head, ctx.keymap);
    return ok;
}

fn cBufferCreate(ctx: *Context, args: struct { name: []const u8 }) anyerror!Value {
    const id = try ctx.buffers.create(ctx.gpa, args.name);
    try ctx.buffers.switchTo(ctx.gpa, id, ctx.head, ctx.keymap);
    return .{ .integer = @intCast(id) };
}

/// Mark the active buffer read-only (tool buffers): text input is
/// swallowed; commands still run.
fn cBufferReadOnly(ctx: *Context, args: struct { on: bool }) anyerror!Value {
    ctx.buffer().read_only = if (args.on) @import("Buffers.zig").produced else null;
    return ok;
}

/// Close the active buffer; a dirty buffer refuses (save or explicitly discard).
///
/// The ACTIVE entry, deliberately — not `ctx.buffer()`. Retiring an entry is a
/// focus-scoped workspace verb, and a background delivery's bound entry names
/// where that delivery WRITES, never what it may close.
fn cBufferClose(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (holdsUnsavedWork(ctx, ctx.buffers.active())) return .{ .string = "dirty" };
    return retireActive(ctx);
}

/// Whether closing `b` would lose work: edits its file never received, or a
/// draft one of its views holds that its provider has not applied (a renamed
/// row in a listing). A listing keeps a view per directory it visited, so
/// every one of them is asked, not only the one it shows.
pub fn holdsUnsavedWork(ctx: *Context, b: *@import("Buffers.zig").Buffer) bool {
    if (b.hasUnsavedFile(ctx.gpa) catch true) return true;
    const services = ctx.semantic orelse return false;
    const focus = if (b.id == ctx.buffers.active_id) &ctx.head.scene_selection else &b.scene_selection;
    if (focus.view) |v| if (services.holdsDraft(v)) return true;
    if (b.tool_view) |v| if (services.holdsDraft(v)) return true;
    for (b.view_cursors.items) |saved| if (services.holdsDraft(saved.view)) return true;
    return false;
}

/// Close the ACTIVE entry: closing is focus-scoped, and a background
/// delivery's bound entry is where it writes, not what it may retire. The
/// shell lets go of what it attached first (`EntryShell.retire`).
fn retireActive(ctx: *Context) anyerror!Value {
    const b = ctx.buffers.active();
    if (ctx.entry_shell) |shell| shell.retire(shell.context, ctx, b);
    try ctx.buffers.close(ctx.gpa, b.id, ctx.head, ctx.keymap);
    return ok;
}

/// Explicitly discard edits in the active buffer. Kept separate from
/// `buffer.close-unmodified` so neither a generic close intention nor a tool's `q` can
/// silently throw away a draft.
fn cBufferCloseForce(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return retireActive(ctx);
}

/// `file.open <designation>` — a local file (a designation, or an absolute
/// path standing in for one; an existing entry wins, deduped by path), and
/// whatever core alone can answer (`designation.openHeld`: documents,
/// processes, projections). A shell with an `EntryShell` answers instead,
/// reaching directories, shells and peers and attaching its providers. A
/// relative path resolves against the place the command runs in
/// (`designation.resolveRelative`).
fn cOpen(ctx: *Context, args: struct { path: []const u8 }) anyerror!Value {
    if (ctx.entry_shell) |shell| return shell.open(shell.context, ctx, args.path);
    switch (designation.durable.Spec.of(args.path)) {
        .relative => {
            const abs = try designation.resolveRelative(ctx, ctx.gpa, args.path) orelse
                return .{ .string = "open: " ++ designation.refuse_relative_elsewhere };
            defer ctx.gpa.free(abs);
            return openFilePath(ctx, abs);
        },
        .malformed => return .{ .string = "open: " ++ designation.durable.Spec.malformed_refusal },
        .path => |path| return openFilePath(ctx, path),
        .designation => |d| {
            if (try designation.openHeld(ctx, d, args.path)) |outcome| switch (outcome) {
                .opened => |id| {
                    designation.applyPosition(ctx, d);
                    return .{ .integer = @intCast(id) };
                },
                .refused => |why| return .{ .string = why },
            };
            if (d.authority != .here or d.kind != .file) return .{ .string = designation.refuse_unreachable };
            const opened = try openFilePath(ctx, d.ref);
            designation.applyPosition(ctx, d);
            return opened;
        },
    }
}

fn openFilePath(ctx: *Context, path: []const u8) anyerror!Value {
    const args = .{ .path = path };
    if (ctx.buffers.findByPath(args.path)) |id| {
        try ctx.buffers.switchTo(ctx.gpa, id, ctx.head, ctx.keymap);
        return .{ .integer = @intCast(id) };
    }
    const id = try ctx.buffers.create(ctx.gpa, std.fs.path.basename(args.path));
    const ed = ctx.buffers.get(id).?.textEditor().?;
    ed.openFile(ctx.gpa, args.path) catch |err| switch (err) {
        error.FileNotFound => try ed.adoptPath(ctx.gpa, args.path),
        else => |e| {
            try ctx.buffers.close(ctx.gpa, id, ctx.head, ctx.keymap);
            return e;
        },
    };
    try ctx.buffers.switchTo(ctx.gpa, id, ctx.head, ctx.keymap);
    return .{ .integer = @intCast(id) };
}

/// Open a previously published semantic target on this dispatching head.
/// The three words are the portable target handle; publication belongs to a
/// filesystem or other producer, never to this generic command.  A missing or
/// ambiguous handler is surfaced as an error so a UI can choose a policy
/// (picker, fallback, or a visible refusal) instead of inheriting one here.
fn cOpenTarget(ctx: *Context, args: struct { authority: i64, slot: i64, generation: i64 }) anyerror!Value {
    const services = ctx.semantic orelse return error.SemanticUnavailable;
    const wire = semantic_model.handle.Wire{
        .authority = try targetWord(args.authority),
        .slot = try targetWord(args.slot),
        .generation = try targetWord(args.generation),
    };
    const result = try target_open.openAndFocus(services, ctx.head, ctx.gpa, semantic_model.target.Ref.fromWire(wire));
    return targetOpenResult(result);
}

/// Open a raw child name below this head's validated working target. The
/// relation provider owns namespace lookup; this command never joins names
/// with a path or falls back to process cwd. It is useful to plugins that
/// have a relative result (grep, run, language tools) without requiring them
/// to know the target's locus.
fn cOpenRelative(ctx: *Context, args: struct { name: []const u8 }) anyerror!Value {
    const services = ctx.semantic orelse return error.SemanticUnavailable;
    const source = (try services.workingTarget(ctx.head)) orelse return error.WorkingTargetUnavailable;
    const result = try target_open.openRelative(services, ctx.head, ctx.gpa, source.located(), args.name);
    return switch (result) {
        .absent => error.RelativeTargetUnavailable,
        .relation_ambiguous => error.AmbiguousRelativeTarget,
        .no_handler => error.NoTargetHandler,
        .handler_ambiguous => error.AmbiguousTargetHandlers,
        .opened => .nil,
    };
}

fn targetOpenResult(result: target_open.Result) anyerror!Value {
    return switch (result) {
        .opened => .nil,
        .no_handler => error.NoTargetHandler,
        .ambiguous => error.AmbiguousTargetHandlers,
    };
}

fn targetWord(value: i64) error{TypeMismatch}!u32 {
    if (value < 0 or value > std.math.maxInt(u32)) return error.TypeMismatch;
    return @intCast(value);
}

/// Re-point the buffer at a new local path and save. Refuses to
/// clobber an existing file (create-guarded) — open it instead if you
/// mean to overwrite its history.
fn cSaveAs(ctx: *Context, args: struct { path: []const u8 }) anyerror!Value {
    if (ctx.buffer().tool.len > 0) return .{ .string = "a projection has no file to write" };
    const ed = ctx.textEditor() catch |e| return editErr(e);
    switch (ed.backing) {
        .none => try ed.adoptPath(ctx.gpa, args.path),
        .file => |*f| {
            const dup = try ctx.gpa.dupe(u8, args.path);
            ctx.gpa.free(f.path);
            f.path = dup;
            if (f.sync.token) |tk| {
                ctx.gpa.free(tk);
                f.sync.token = null; // guard on non-existence at the new path
            }
        },
        .remote => return .{ .string = "file.save-as: a remote file saves where it is" },
    }
    try ed.requestSave(ctx.gpa);
    return ok;
}

/// Show a transient message on the status line — the generic surface
/// plugins and commands report through (cleared by the next echo).
fn echoLine(ctx: *Context, text: []const u8) void {
    ctx.head.echo.clearRetainingCapacity();
    ctx.head.echo.appendSlice(ctx.gpa, text) catch {};
}

fn cEcho(ctx: *Context, args: struct { text: []const u8 }) anyerror!Value {
    ctx.head.echo.clearRetainingCapacity();
    try ctx.head.echo.appendSlice(ctx.gpa, args.text);
    return ok;
}

/// Show or hide a DECLARED viewport by name — the one door a "toggle the
/// sidebar" key needs, without core learning what a sidebar is. It records
/// the intent on the declaration; the layout phase docks or undocks to match.
fn cViewportToggle(ctx: *Context, args: struct { name: []const u8 }) anyerror!Value {
    const registry = ctx.viewports orelse return .{ .string = "no workspace to hold a viewport" };
    _ = registry.toggle(args.name) catch return .{ .string = "no viewport by that name" };
    if (ctx.context) |context| registry.publishShown(context);
    return ok;
}

/// Bring the ACTIVE entry into a declared viewport, show the viewport, and
/// focus it there — replacing whatever it showed. How a plugin puts its own
/// entry (a terminal, a list of problems) in a panel the config declared:
/// focus-or-create the entry, then take it. The pane the command ran in keeps
/// what it showed; the layout phase realizes the move.
fn cViewportTake(ctx: *Context, args: struct { name: []const u8 }) anyerror!Value {
    const registry = ctx.viewports orelse return .{ .string = "no workspace to hold a viewport" };
    // A viewport holds WHAT it shows, never the slot it was shown from.
    var buf: [designation.max_len]u8 = undefined;
    const held = designation.of(ctx.buffers.active(), &buf) orelse
        return .{ .string = "this entry has no designation for a viewport to hold" };
    registry.takeEntry(ctx.gpa, args.name, held) catch |err| return switch (err) {
        error.UnknownViewport => .{ .string = "no viewport by that name" },
        else => err,
    };
    if (ctx.context) |context| registry.publishShown(context);
    return ok;
}

fn providerLabel(p: container_mod.ProviderRef) []const u8 {
    return switch (p) {
        .command => |c| c,
        .caps_provider => |r| r.id,
        .value => |c| c,
        .ui_provider => "ui_provider",
        .schema_provider => |r| r.owner,
    };
}

/// `explain-binding <slot>` — the Container's `explain`
/// (doc/configuration.md §7) wired to a REAL consumer, not a debug printf:
/// echoes which bindings on an ACTION slot are eligible for the active
/// buffer's facts and why the winner won. The facts mirror
/// `Context.actionCtx` (same mode/lang/tool) plus the buffer's path/name, so
/// `explain-binding eval` answers exactly the question
/// `Actions.resolve("eval", ...)` would have asked.
fn cExplainBinding(ctx: *Context, args: struct { slot: []const u8 }) anyerror!Value {
    // The one fact builder resolution itself uses (`intent.factsFor`), so the
    // explanation cannot disagree with what a key or a toolbar would run — a
    // provider keyed on `role`, `locality` or `posture` is explained too.
    const f: facts.Facts = @import("intent.zig").factsFor(ctx);
    var ex = try ctx.actions.container.explain(ctx.gpa, args.slot, f);
    defer ex.deinit();

    ctx.head.echo.clearRetainingCapacity();
    if (ex.eligible.len == 0) {
        try ctx.head.echo.appendSlice(ctx.gpa, "action.explain: no eligible binding");
        return ok;
    }
    const w = ex.eligible[ex.winner.?];
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: {d} eligible, winner={s} (owner={s} tier={s} priority={d} specificity={d}){s}", .{
        args.slot,
        ex.eligible.len,
        providerLabel(w.provider),
        w.owner,
        @tagName(w.tier),
        w.priority,
        w.specificity,
        if (ex.collision) " COLLISION" else "",
    }) catch "action.explain: (result too long to display)";
    try ctx.head.echo.appendSlice(ctx.gpa, msg);
    return ok;
}

const table = [_]command.Command{
    command.define("action.explain", "Explain which binding wins an action slot for the active buffer, and why.", cExplainBinding).present(.{ .label = "Explain Binding", .menu = "Help", .group = "keys", .order = 20, .prompts = true }),
    command.define("edit.insert-text", "Insert text at the cursor, replacing the selection.", cInsertText).present(.{ .internal = true }),
    command.define("buffer.next", "Switch to the next buffer, wrapping around at the end.", cBufferNext).present(.{ .label = "Next Buffer", .menu = "Go", .group = "buffers", .order = 10, .icon = "chevron-right" }),
    command.define("buffer.prev", "Switch to the previous buffer, wrapping around at the start.", cBufferPrevious).present(.{ .label = "Previous Buffer", .menu = "Go", .group = "buffers", .order = 20, .icon = "chevron-left" }),
    command.define("buffer.back", "Return to the buffer that was active before this one.", cBufferBack).present(.{ .label = "Last Buffer", .menu = "Go", .group = "buffers", .order = 30 }),
    command.define("buffer.switch", "Switch to the buffer with the given id.", cBufferSwitch).present(.{ .internal = true }),
    command.define("buffer.create", "Create a named scratch buffer and switch to it.", cBufferCreate).present(.{ .label = "New Named Buffer", .prompts = true }),
    command.define("buffer.close-unmodified", "Close the active buffer, refusing when it has unsaved edits.", cBufferClose).present(.{ .internal = true }),
    command.define("buffer.close-force", "Close the active buffer, discarding its unsaved edits.", cBufferCloseForce).present(.{ .label = "Close Without Saving", .menu = "File", .group = "close", .order = 20 }),
    command.define("buffer.set-read-only", "Make the active buffer read-only, or writable again.", cBufferReadOnly).present(.{ .internal = true }),
    command.define("file.open", "Open a file in a buffer, reusing the buffer that already shows it.", cOpen).present(.{ .label = "Open", .menu = "File", .group = "open", .order = 5, .icon = "folder-open", .prompts = true }),
    command.define("target.open-published", "Open and focus a published semantic target.", cOpenTarget).present(.{ .internal = true }),
    command.define("target.open-relative", "Open a name relative to the current working target.", cOpenRelative).present(.{ .internal = true }),
    // A transfer is ONE value: copy and cut send every selected row as one
    // request and get one transfer (a set) back — per extent, each run would
    // overwrite the last. Paste reads the whole selection the same way (a
    // provider refuses a paste beside several rows as ambiguous).
    command.define("selection.copy", "Copy the selection.", cSelectionCopy).maps(.whole).present(.{ .label = "Copy", .menu = "Edit", .group = "clipboard", .order = 20, .icon = "copy" }),
    command.define("selection.cut", "Cut the selection.", cSelectionCut).maps(.whole).present(.{ .label = "Cut", .menu = "Edit", .group = "clipboard", .order = 10, .icon = "scissors" }),
    command.define("selection.delete", "Delete the selection.", cSelectionDelete).maps(.each_extent).present(.{ .label = "Delete", .menu = "Edit", .group = "clipboard", .order = 50 }),
    command.define("selection.paste-before", "Paste before the selection.", cSelectionPasteBefore).maps(.whole).present(.{ .label = "Paste Before", .menu = "Edit", .group = "clipboard", .order = 30 }),
    command.define("selection.paste-after", "Paste after the selection.", cSelectionPasteAfter).maps(.whole).present(.{ .label = "Paste After", .menu = "Edit", .group = "clipboard", .order = 40, .icon = "clipboard-paste" }),
    command.define("target.open", "Open what the focused row or selection points at.", cTargetOpenFocused).maps(.each_extent).present(.{ .label = "Open" }),
    command.define("hierarchy.toggle-expanded", "Expand the focused row, or collapse it when it is open.", cHierarchyToggleExpanded).maps(.each_extent).present(.{ .label = "Expand/Collapse" }),
    // One row's verbs: a name edited, a row inserted beside it, its container
    // stepped out to. On several marked rows none has a meaning (which name?
    // beside which row?), so they are refused there rather than acting on the
    // focused row alone.
    command.define("target.open-container", "Open the container that holds the focused row.", cHierarchyStepOut).maps(null).present(.{ .label = "Up to Parent" }),
    command.define("item.insert-before", "Insert a new item before the focused one.", cItemInsertBefore).maps(null).present(.{ .label = "Insert Before" }),
    command.define("item.insert-after", "Insert a new item after the focused one.", cItemInsertAfter).maps(null).present(.{ .label = "Insert After" }),
    command.define("field.edit", "Start editing the focused row's main field.", cFieldEdit).maps(null).present(.{ .label = "Edit" }),
    command.define("field.commit-edit", "Finish the field edit, applying the change when there is one.", cFieldEditCommit).present(.{ .internal = true }),
    command.define("field.cancel-edit", "Cancel the field edit, restoring the original text.", cFieldEditCancel).present(.{ .internal = true }),
    command.define("mode.set-structural-focus", "Declare whether the grammar focuses a structural row as a row or edits its field as text.", cStructuralFocus).present(.{ .internal = true }),
    command.define("view.refresh", "Refresh the focused view.", cViewRefresh).present(.{ .label = "Refresh" }),
    command.define("view.revert", "Discard the focused view's draft and show it as it is.", cViewRevert).present(.{ .label = "Revert" }),
    command.define("view.apply", "Apply the focused view's draft.", cViewApply).present(.{ .label = "Apply" }),
    command.define("app.echo", "Show a message on the status line.", cEcho).present(.{ .internal = true }),
    command.define("viewport.toggle", "Show or hide a named viewport.", cViewportToggle).present(.{ .label = "Toggle Viewport", .prompts = true }),
    command.define("viewport.take", "Show the active entry in a named viewport and focus it there.", cViewportTake).present(.{ .label = "Move to Viewport", .prompts = true }),
    command.define("file.save-as", "Save the buffer to a new path, refusing to overwrite an existing file.", cSaveAs).present(.{ .label = "Save As", .menu = "File", .group = "save", .order = 20, .prompts = true }),
    command.define("edit.delete-before", "Delete the selection, or the character before the cursor.", cDeleteBackward).present(.{ .label = "Delete Backward" }),
    command.define("edit.delete-after", "Delete the selection, or the character after the cursor.", cDeleteForward).present(.{ .label = "Delete Forward" }),
    command.define("edit.undo", "Undo your most recent edit.", cUndo).present(.{ .label = "Undo", .menu = "Edit", .group = "history", .order = 10, .icon = "undo" }),
    command.define("edit.redo", "Redo the edit you most recently undid.", cRedo).present(.{ .label = "Redo", .menu = "Edit", .group = "history", .order = 20, .icon = "redo" }),
    command.define("file.write", "Write the buffer to its file.", cSaveFile).present(.{ .internal = true }),
    command.define("field.word-prev", "Move the field cursor to the start of the previous word.", fieldMotion(.word_previous)).present(.{ .internal = true }),
    command.define("field.word-next", "Move the field cursor to the start of the next word.", fieldMotion(.word_next)).present(.{ .internal = true }),
    command.define("field.word-end", "Move the field cursor to the end of the word.", fieldMotion(.word_end)).present(.{ .internal = true }),
    command.define("field.big-word-prev", "Move the field cursor to the start of the previous WORD.", fieldMotion(.WORD_previous)).present(.{ .internal = true }),
    command.define("field.big-word-next", "Move the field cursor to the start of the next WORD.", fieldMotion(.WORD_next)).present(.{ .internal = true }),
    command.define("field.big-word-end", "Move the field cursor to the end of the WORD.", fieldMotion(.WORD_end)).present(.{ .internal = true }),
    command.define("field.line-start", "Move the field cursor to the start of the line.", fieldMotion(.line_start)).present(.{ .internal = true }),
    command.define("field.line-end", "Move the field cursor to the end of the line.", fieldMotion(.line_end)).present(.{ .internal = true }),
    command.define("field.first-non-blank", "Move the field cursor to the first non-blank character.", fieldMotion(.first_non_blank)).present(.{ .internal = true }),
    command.define("cursor.left", "Move the cursor one character left.", cCursorLeft).maps(.each_extent).present(.{ .label = "Cursor Left" }),
    command.define("cursor.right", "Move the cursor one character right.", cCursorRight).maps(.each_extent).present(.{ .label = "Cursor Right" }),
    command.define("cursor.up", "Move the cursor up one line.", cCursorUp).maps(.each_extent).present(.{ .label = "Cursor Up" }),
    command.define("cursor.down", "Move the cursor down one line.", cCursorDown).maps(.each_extent).present(.{ .label = "Cursor Down" }),
    command.define("cursor.row-down", "Move to the next row, onto its actionable part.", cRowDown).present(.{ .internal = true }),
    command.define("cursor.row-up", "Move to the previous row, onto its actionable part.", cRowUp).present(.{ .internal = true }),
    command.define("selection.start", "Start a selection at the cursor.", cSetMark).maps(.each_extent).present(.{ .label = "Start Selection" }),
    command.define("selection.start-rows", "Start selecting a range of rows at the focused row.", cMarkRows).maps(.each_extent).present(.{ .label = "Select Rows" }),
    command.define("selection.clear", "Drop the selection.", cClearSelection).maps(.each_extent).present(.{ .label = "Clear Selection" }),
    command.define("edit.seal-undo", "Close the current undo step so the next edit starts a new one.", cUndoBarrier).present(.{ .internal = true }),
    command.define("mode.set", "Switch the keymap mode.", cSetMode).present(.{ .internal = true }),
    command.define("mode.break-out", "Leave a capturing mode for the mode it replaced.", cPostureBreakOut).present(.{ .internal = true }),
    command.define("app.quit", "Quit the editor.", cQuit).present(.{ .label = "Quit", .menu = "File", .group = "exit", .order = 10, .icon = "log-out" }),
    command.define("edit.insert-newline", "Insert a line break at the cursor.", cInsertNewline).present(.{ .label = "Insert Newline" }),
    command.define("edit.insert-tab", "Insert a tab at the cursor.", cInsertTab).present(.{ .label = "Insert Tab" }),
};

/// `file.write`'s eligibility: any entry whose bytes are not a tool projection.
const not_a_projection: facts.Predicate = .{ .locus = .tool };

/// Register every built-in and the default keymap. The default mode is
/// plain modeless editing; a config replaces any of it by rebinding.
pub fn install(gpa: std.mem.Allocator, commands: *command.Commands, keymap: *@import("Keymap.zig"), head: *@import("Head.zig"), actions: *@import("action.zig")) !void {
    for (table) |cmd| _ = try commands.bind(gpa, cmd.name, cmd);
    // The generic pointer commands: the modeless floor for a click, a drag,
    // and a wheel step. Which gesture runs which is config (defaults.js).
    try @import("pointer.zig").install(gpa, commands);
    // The jumplist's travel (C-o/C-i and a picker). Which keys, and which
    // motions count as jumps, is the grammar's.
    try @import("jumplist.zig").install(gpa, commands);

    // `save` is an ACTION: `C-s`/`:w`/palette all dispatch it, and a projection
    // (files/git) provides its own `save` scoped to its tool identity, which
    // wins in its buffer. The default provider writes the file backing, so it
    // claims only entries whose bytes are NOT a tool's projection: a git status
    // listing has nothing durable to write, and saying so here — by a fact, in
    // the provider's own eligibility — is what lets `std.persistence.save` be
    // absent there instead of offered and then refused (`intent.zig`).
    //
    // Priority -1 keeps it the FLOOR it was when it was unconstrained: the
    // `not` makes it one conjunct specific, which would otherwise tie (and
    // collide at bind) with every projection's own one-conjunct `tool` save.
    try command.registerAction(gpa, commands, actions, "file.save", .pick, "Save the focused entry: write a file, apply a listing's draft, send a commit message.", .{
        .label = "Save",
        .menu = "File",
        .group = "save",
        .order = 10,
        .icon = "save",
    });
    try actions.provide(.{ .action = "file.save", .predicate = .{ .not = &not_a_projection }, .command = "file.write", .priority = -1, .owner = "core" });

    // Retiring an entry is an ACTION too, for the same reason `save` is: what a
    // tool's entry is worth is the tool's question. The default provider drops
    // it (refusing an unsaved file); a projection whose text is unrecoverable —
    // a commit draft — provides its own and asks first.
    try command.registerAction(gpa, commands, actions, "buffer.close", .pick, "Close the focused entry, letting its provider refuse when it holds unsaved work.", .{
        .label = "Close Editor",
        .menu = "File",
        .group = "close",
        .order = 10,
        .icon = "close",
    });
    try actions.provide(.{ .action = "buffer.close", .command = "buffer.close-unmodified", .owner = "core" });

    // NO BLANKET std VOCABULARY FOR A TOOL LOCUS.
    //
    // There was one here: eight `provide`s scoped to `.locus = .tool`, so any
    // tool entry answered `down`, `activate`, `toggle-expanded`, the transfer
    // verbs. It made a std-only grammar drive a listing, which was the point,
    // and it was wrong in the way a blanket claim is always wrong — it said a
    // FILE row affords folding and an empty listing affords yanking, because it
    // could not see what point was on. `explain` then reported `ready` for a
    // key that would do nothing.
    //
    // `view_offers.zig` derives the same vocabulary from what the SUBJECT
    // advertises, and now asks that question of a text projection as well as of
    // a scene. A verb is offered where it applies, disabled with a reason where
    // the producer refused it, and absent where the row does not afford it —
    // one rule, derived, for both planes.

    // The "default" (modeless) mode's baseline editing keys — so BARE weft (run
    // with no config at all) can still type/edit. These are the ONE binding set
    // core ships, precisely because they must exist before any config loads; a
    // config that loads an editor plugin (vim/helix) drives its own modes, and a
    // config can rebind these at the higher config tier. (The picker + which-key
    // nav binds, which only matter once a config's UI is up, are config data —
    // defaults.js. This is the modeless floor, not app policy.)
    // mechanism-not-policy (task #19 item 3): install-time bootstrap, before
    // any `*command.Context` exists to capture a `Ctx` from — the raw
    // mechanism entry (`Head.setModeRaw`) is the only door reachable here.
    try head.setModeRaw(gpa, "default");
    const binds = [_][2][]const u8{
        .{ "BackSpace", "edit.delete-before" },
        .{ "Delete", "edit.delete-after" },
        .{ "Tab", "edit.insert-tab" },
        .{ "Left", "cursor.left" },
        .{ "Right", "cursor.right" },
        .{ "Up", "cursor.up" },
        .{ "Down", "cursor.down" },
        .{ "C-s", "file.save" },
        .{ "C-z", "edit.undo" },
        .{ "C-y", "edit.redo" },
        .{ "C-space", "selection.start" },
        .{ "C-g", "selection.clear" },
        .{ "C-q", "app.quit" },
        .{ "C-b", "buffer.pick" },
        .{ "C-Tab", "buffer.next" },
    };
    const Keymap = @import("Keymap.zig");
    for (binds) |b| try keymap.bind(gpa, "default", b[0], b[1], Keymap.prio_core, "core");
    // Return is the fallback-list case (architecture §10.2): activate the
    // focused target if anything offers that here, else break the line. In a
    // text entry only the second arm has an offer, so this is the modeless
    // floor's `edit.insert-newline`, reached through the catalog instead of by
    // name.
    const enter = [_][]const u8{ "std.target.activate", "std.editing.insert-line-break" };
    for ([_][]const u8{ "Return", "KP_Enter" }) |key|
        try keymap.bindArms(gpa, "default", key, &enter, Keymap.prio_core, "core");
    try keymap.setCommitCommand(gpa, "default", "edit.insert-text");

    try @import("pick.zig").install(gpa, commands, keymap);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "builtins: explain-binding is a real consumer of Container.explain" {
    const gpa = t.allocator;
    const task = @import("task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var buffers = try @import("Buffers.zig").init(gpa, pool, "user");
    defer buffers.deinit(gpa);
    var keymap: @import("Keymap.zig") = .empty;
    defer keymap.deinit(gpa);
    var head: @import("Head.zig") = .empty;
    defer head.deinit(gpa);
    var container = @import("container.zig").Container.init(gpa);
    defer container.deinit();
    var caps = @import("capability.zig").Caps.init(gpa, task.nowNs, &container);
    defer caps.deinit();
    var actions = Actions.init(gpa, &container);
    defer actions.deinit();
    var quit = false;
    var commands: command.Commands = .empty;
    defer commands.deinit(gpa);
    try install(gpa, &commands, &keymap, &head, &actions);

    // A second, higher-priority projection provider, so `action.explain` has
    // more than one eligible binding to report on.
    try actions.provide(.{ .action = "file.save", .command = "projection-save", .priority = 10, .owner = "projection" });

    var ctx: Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .actions = &actions,
        .caps = &caps,
        .quit = &quit,
        .head = &head,
    };

    _ = try command.run(&commands, &ctx, "action.explain", &.{.{ .string = "file.save" }});
    try t.expect(std.mem.indexOf(u8, head.echo.items, "projection-save") != null);
    try t.expect(std.mem.indexOf(u8, head.echo.items, "2 eligible") != null);

    // An unknown slot: no eligible bindings, no crash, an honest echo.
    _ = try command.run(&commands, &ctx, "action.explain", &.{.{ .string = "nonexistent-slot" }});
    try t.expect(std.mem.indexOf(u8, head.echo.items, "no eligible binding") != null);
}

test {
    std.testing.refAllDecls(@This());
}
