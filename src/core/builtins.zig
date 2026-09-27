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
        .summary = "semantic action",
        .args = &.{},
        .handler = semanticActionTrampoline,
        .data = target,
        .arity = semanticArity(name),
    });
}

/// How an open semantic action maps over several selected rows. The standard
/// vocabulary says: a `selection.*` action and `target.open` act on each row;
/// a `view.*` action acts on the view once. Any other name says nothing, so
/// it is refused on several rows rather than run on the focused one alone.
fn semanticArity(name: []const u8) ?@import("selection.zig").Arity {
    if (std.mem.startsWith(u8, name, "selection.") or std.mem.eql(u8, name, semantic_model.action.standard.open))
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
    _ = try services.requestFocusedFieldEdit(ctx.head, ctx.gpa);
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
    const ed = ctx.textEditor() catch |e| return editErr(e);
    ed.moveUp();
    return ok;
}

fn cCursorDown(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticMove(ctx, .next)) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    ed.moveDown();
    return ok;
}

/// Move point to the next/previous ROW of a projection, landing where that row
/// is ACTIONABLE — the start of its editable span when it has one, its own
/// start otherwise.
///
/// A listing is text, so plain `cursor-down` works on it; what plain cursor
/// motion cannot do is land you on the NAME. Column 0 of `  ▸ src` is an
/// indent, and a grammar asking "may I insert here" gets `structural` there and
/// `field` two characters along — so navigating a listing with `cursor-down`
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

/// `mark-rows`: anchor a range of ROWS at the focused one, whatever part of
/// the row is focused — a listing focuses a row's name field, where
/// `set-mark` selects text in the field (vim's `v`); a linewise mark over
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
    ctx.buffer().read_only = args.on;
    return ok;
}

/// Close the active buffer; a dirty buffer refuses (save or explicitly discard).
///
/// The ACTIVE entry, deliberately — not `ctx.buffer()`. Retiring an entry is a
/// focus-scoped workspace verb, and a background delivery's bound entry names
/// where that delivery WRITES, never what it may close.
fn cBufferClose(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    const b = ctx.buffers.active();
    if (b.hasUnsavedFile(ctx.gpa) catch true) return .{ .string = "dirty" };
    try ctx.buffers.close(ctx.gpa, b.id, ctx.head, ctx.keymap);
    return ok;
}

/// Explicitly discard edits in the active buffer. Kept separate from
/// `buffer-close` so neither a generic close intention nor a tool's `q` can
/// silently throw away a draft.
fn cBufferCloseForce(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.buffers.close(ctx.gpa, ctx.buffers.active().id, ctx.head, ctx.keymap);
    return ok;
}

/// Open a local file in a buffer (existing buffer wins — dedupe by
/// path). The graphical shell rebinds this with a provider-aware,
/// remote-capable version; this core one keeps headless hosts honest.
/// `open <designation>` — the kernel's own: a local file (a designation, or
/// an absolute path standing in for one), and whatever core alone can answer
/// (`designation.openHeld`: documents, processes, projections). A shell
/// shadows this with one that also reaches directories, shells and peers,
/// and routes the same way. A relative path resolves against the place the
/// command runs in (`designation.resolveRelative`).
fn cOpen(ctx: *Context, args: struct { path: []const u8 }) anyerror!Value {
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
        .shell => return .{ .string = "unsupported backing for save-as" },
    }
    try ed.requestSave(ctx.gpa);
    return ok;
}

/// Show a transient message on the status line — the generic surface
/// plugins and commands report through (cleared by the next echo).
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
        try ctx.head.echo.appendSlice(ctx.gpa, "explain-binding: no eligible binding");
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
    }) catch "explain-binding: (result too long to display)";
    try ctx.head.echo.appendSlice(ctx.gpa, msg);
    return ok;
}

const table = [_]command.Command{
    command.define("explain-binding", "Explain which Container binding wins an action slot for the active buffer's facts.", cExplainBinding),
    command.define("insert-text", "Insert text at the cursor (replaces the selection).", cInsertText),
    command.define("buffer-next", "Focus the next buffer (cyclic).", cBufferNext),
    command.define("buffer-previous", "Focus the previous buffer (cyclic).", cBufferPrevious),
    command.define("buffer-back", "Return to the previously active buffer (tool `q`).", cBufferBack),
    command.define("buffer-switch", "Focus the buffer with the given id.", cBufferSwitch),
    command.define("buffer-create", "Create (and focus) a named scratch buffer.", cBufferCreate),
    command.define("buffer-close", "Close the active buffer (refuses when dirty).", cBufferClose),
    command.define("buffer-close-force", "Close the active buffer, discarding unsaved edits.", cBufferCloseForce),
    command.define("buffer-read-only", "Set/clear the active buffer's read-only flag.", cBufferReadOnly),
    command.define("open", "Open a file in a buffer (dedupes by path).", cOpen),
    command.define("open-target", "Open and focus a published semantic target.", cOpenTarget),
    command.define("open-relative", "Open a raw name below the semantic working target.", cOpenRelative),
    command.define("selection-copy", "Invoke the focused semantic selection.copy action.", cSelectionCopy).maps(.each_extent),
    command.define("selection-cut", "Invoke the focused semantic selection.cut action.", cSelectionCut).maps(.each_extent),
    command.define("selection-delete", "Invoke the focused semantic selection.delete action.", cSelectionDelete).maps(.each_extent),
    command.define("selection-paste-before", "Invoke the focused semantic selection.paste-before action.", cSelectionPasteBefore).maps(.each_extent),
    command.define("selection-paste-after", "Invoke the focused semantic selection.paste-after action.", cSelectionPasteAfter).maps(.each_extent),
    command.define("target-open-focused", "Invoke the focused semantic target.open action.", cTargetOpenFocused).maps(.each_extent),
    command.define("hierarchy-toggle-expanded", "Invoke the focused semantic hierarchy.toggle-expanded action.", cHierarchyToggleExpanded).maps(.each_extent),
    command.define("hierarchy-step-out", "Invoke the focused semantic target.open-container action.", cHierarchyStepOut),
    command.define("item-insert-before", "Insert an item before focus.", cItemInsertBefore),
    command.define("item-insert-after", "Insert an item after focus.", cItemInsertAfter),
    command.define("field-edit", "Invoke the focused semantic field.edit action.", cFieldEdit),
    command.define("view-refresh", "Invoke the focused semantic view.refresh action.", cViewRefresh),
    command.define("view-revert", "Invoke the focused semantic view.revert action.", cViewRevert),
    command.define("view-apply", "Invoke the focused semantic view.apply action.", cViewApply),
    command.define("echo", "Show a message on the status line.", cEcho),
    command.define("viewport-toggle", "Show or hide a declared viewport.", cViewportToggle),
    command.define("viewport-take", "Show the active entry in a declared viewport, and focus it there.", cViewportTake),
    command.define("save-as", "Save to a new path (refuses to clobber an existing file).", cSaveAs),
    command.define("delete-backward", "Delete the selection or the character before the cursor.", cDeleteBackward),
    command.define("delete-forward", "Delete the selection or the character after the cursor.", cDeleteForward),
    command.define("undo", "Undo the newest own edit unit.", cUndo),
    command.define("redo", "Redo the newest undone unit.", cRedo),
    command.define("save-file", "Write the buffer to its file backing (the default `save` provider).", cSaveFile),
    command.define("field-word-previous", "Move the focused field to the word-previous boundary.", fieldMotion(.word_previous)),
    command.define("field-word-next", "Move the focused field to the word-next boundary.", fieldMotion(.word_next)),
    command.define("field-word-end", "Move the focused field to the word-end boundary.", fieldMotion(.word_end)),
    command.define("field-big-word-previous", "Move the focused field to the WORD-previous boundary.", fieldMotion(.WORD_previous)),
    command.define("field-big-word-next", "Move the focused field to the WORD-next boundary.", fieldMotion(.WORD_next)),
    command.define("field-big-word-end", "Move the focused field to the WORD-end boundary.", fieldMotion(.WORD_end)),
    command.define("field-line-start", "Move the focused field to the line-start boundary.", fieldMotion(.line_start)),
    command.define("field-line-end", "Move the focused field to the line-end boundary.", fieldMotion(.line_end)),
    command.define("field-first-non-blank", "Move the focused field to the first-non-blank boundary.", fieldMotion(.first_non_blank)),
    command.define("cursor-left", "Move the cursor one character left.", cCursorLeft).maps(.each_extent),
    command.define("cursor-right", "Move the cursor one character right.", cCursorRight).maps(.each_extent),
    command.define("cursor-up", "Move the cursor up one line.", cCursorUp).maps(.each_extent),
    command.define("cursor-down", "Move the cursor down one line.", cCursorDown).maps(.each_extent),
    command.define("row-down", "Move to the next projection row, on its actionable part.", cRowDown),
    command.define("row-up", "Move to the previous projection row, on its actionable part.", cRowUp),
    command.define("set-mark", "Start a selection at the cursor.", cSetMark).maps(.each_extent),
    command.define("mark-rows", "Start a range of rows at the focused row of a scene.", cMarkRows).maps(.each_extent),
    command.define("clear-selection", "Drop the selection.", cClearSelection).maps(.each_extent),
    command.define("undo-barrier", "Seal the undo unit; the next edit starts a new one.", cUndoBarrier),
    command.define("set-mode", "Switch the keymap mode.", cSetMode),
    command.define("posture-break-out", "Leave a capture posture for the one it displaced.", cPostureBreakOut),
    command.define("quit", "Exit the editor.", cQuit),
    command.define("insert-newline", "Insert a line break at the cursor.", cInsertNewline),
    command.define("insert-tab", "Insert a tab at the cursor.", cInsertTab),
};

/// `save-file`'s eligibility: any entry whose bytes are not a tool projection.
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
    try command.registerAction(gpa, commands, actions, "save", .pick);
    try actions.provide(.{ .action = "save", .predicate = .{ .not = &not_a_projection }, .command = "save-file", .priority = -1, .owner = "core" });

    // Retiring an entry is an ACTION too, for the same reason `save` is: what a
    // tool's entry is worth is the tool's question. The default provider drops
    // it (refusing an unsaved file); a projection whose text is unrecoverable —
    // a commit draft — provides its own and asks first.
    try command.registerAction(gpa, commands, actions, "close", .pick);
    try actions.provide(.{ .action = "close", .command = "buffer-close", .owner = "core" });

    // Input models express leaving a transient/tool locus as an intent. Vim's
    // `q` is one such mapping; another editor can choose another key, and a
    // more specific provider can override this buffer-history implementation.
    // It is deliberately NOT the jumplist's back: leaving a tool must leave
    // it, while the last jump is often inside the same entry (`jumplist.zig`).
    try command.registerAction(gpa, commands, actions, "navigate-back", .pick);
    try actions.provide(.{ .action = "navigate-back", .command = "buffer-back", .owner = "core" });

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
        .{ "BackSpace", "delete-backward" },
        .{ "Delete", "delete-forward" },
        .{ "Tab", "insert-tab" },
        .{ "Left", "cursor-left" },
        .{ "Right", "cursor-right" },
        .{ "Up", "cursor-up" },
        .{ "Down", "cursor-down" },
        .{ "C-s", "save" },
        .{ "C-z", "undo" },
        .{ "C-y", "redo" },
        .{ "C-space", "set-mark" },
        .{ "C-g", "clear-selection" },
        .{ "C-q", "quit" },
        .{ "C-b", "buffers" },
        .{ "C-Tab", "buffer-next" },
    };
    const Keymap = @import("Keymap.zig");
    for (binds) |b| try keymap.bind(gpa, "default", b[0], b[1], Keymap.prio_core, "core");
    // Return is the fallback-list case (architecture §10.2): activate the
    // focused target if anything offers that here, else break the line. In a
    // text entry only the second arm has an offer, so this is the modeless
    // floor's `insert-newline`, reached through the catalog instead of by
    // name.
    const enter = [_][]const u8{ "std.target.activate", "std.editing.insert-line-break" };
    for ([_][]const u8{ "Return", "KP_Enter" }) |key|
        try keymap.bindArms(gpa, "default", key, &enter, Keymap.prio_core, "core");
    try keymap.setCommitCommand(gpa, "default", "insert-text");

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

    // A second, higher-priority projection provider, so `explain-binding` has
    // more than one eligible binding to report on.
    try actions.provide(.{ .action = "save", .command = "projection-save", .priority = 10, .owner = "projection" });

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

    _ = try command.run(&commands, &ctx, "explain-binding", &.{.{ .string = "save" }});
    try t.expect(std.mem.indexOf(u8, head.echo.items, "projection-save") != null);
    try t.expect(std.mem.indexOf(u8, head.echo.items, "2 eligible") != null);

    // An unknown slot: no eligible bindings, no crash, an honest echo.
    _ = try command.run(&commands, &ctx, "explain-binding", &.{.{ .string = "nonexistent-slot" }});
    try t.expect(std.mem.indexOf(u8, head.echo.items, "no eligible binding") != null);
}

test {
    std.testing.refAllDecls(@This());
}
