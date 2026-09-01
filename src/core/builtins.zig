//! Built-in commands. Everything user-visible goes through the command
//! ABI — these are ordinary typed functions the same `define` machinery
//! wraps, registered under the same late-binding names a config or
//! plugin may shadow. If a built-in can't live behind this door, the
//! core is wrong (the manifesto's test).

const std = @import("std");

const command = @import("command.zig");
const Context = command.Context;
const Value = command.Value;
const facts = @import("weft_facts");
const container_mod = @import("container.zig");
const Actions = @import("action.zig");
const target_open = @import("target_open.zig");
const semantic_model = @import("weft_semantic");
const placement = @import("placement.zig");

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
    if (ctx.semantic) |services| {
        if (services.invokeFocusedAction(&ctx.head.interactions, ctx.head, ctx.gpa, action_name)) |_| {
            return ok;
        } else |err| switch (err) {
            error.ActionUnavailable, error.StaleView => {},
            else => return err,
        }
    }
    // ONE ACTION NAME, EITHER PLANE.
    //
    // `view.apply`, `fs.entry.create-file`, `selection.delete` are what a
    // person means, and a config binds the NAME. Which plane answers is not
    // their business: a scene-backed view answers through its focused node, and
    // a producer whose view is a text PROJECTION answers by `provide`-ing the
    // same name against what the row under point IS. Without this the two
    // planes needed two vocabularies for one idea, which is exactly the fork
    // doc/plugin-api.md §F2 is about.
    //
    // An action nobody claims is still a no-op, as it always was — an ordinary
    // text buffer has no `view.apply` and says so by silence.
    const cmd = ctx.actions.resolveFacts(action_name, ctx.capturedCtx().mergedFacts()) orelse return ok;
    _ = try command.run(ctx.commands, ctx, cmd, &.{});
    return ok;
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
    });
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
    // A scene may deliberately expose custom open behavior without linking a
    // registered target. Preserve that generic action-provider escape hatch;
    // a present typed link never falls through on stale/ambiguous resolution.
    const located = try services.focusedTarget(ctx.head) orelse
        return invokeSemanticAction(ctx, semantic_model.action.standard.open);
    const result = try target_open.openLocated(services, ctx.head, ctx.gpa, located, null);
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

fn cInsertText(ctx: *Context, args: struct { text: []const u8 }) anyerror!Value {
    if (try semanticFieldInput(ctx, .{ .commit = .from(args.text) })) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    ctx.edit(ed.insertRange(), args.text) catch |e| return editErr(e);
    return ok;
}

fn cDeleteBackward(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticFieldInput(ctx, .delete_previous)) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    const r = ed.backspaceRange() orelse return ok;
    ctx.edit(r, "") catch |e| return editErr(e);
    return ok;
}

fn cDeleteForward(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticFieldInput(ctx, .delete_next)) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    const r = ed.forwardRange() orelse return ok;
    ctx.edit(r, "") catch |e| return editErr(e);
    return ok;
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
    return undid(ed.undo(ctx.gpa, ctx.undoGate()));
}

fn cRedo(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    const ed = ctx.textEditor() catch return .{ .boolean = false };
    return undid(ed.redo(ctx.gpa, ctx.undoGate()));
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
    const at = if (here) |n| n.start else ed.cursorOffset();
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
    ed.placeCursor(target.start + if (target.editable) |e| e.start else 0);
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

// Word/WORD/line/doc motions and match-bracket moved to the `motions` plugin
// (design §6.1 — they return a `range` an operator awaits). Core keeps only the
// grapheme/line step primitive (`editor.step`, exposed via cursor-*) and the
// selection write-half (set-mark/clear-selection) below.

fn cSetMark(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    try ed.setMark(ctx.gpa);
    return ok;
}

fn cClearSelection(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    ed.clearSelection();
    return ok;
}

fn cUndoBarrier(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
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
    const ed = ctx.textEditor() catch |e| return editErr(e);
    ctx.edit(ed.insertRange(), "\n") catch |e| return editErr(e);
    return ok;
}

fn cInsertTab(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticFieldInput(ctx, .{ .commit = .none })) return ok;
    const ed = ctx.textEditor() catch |e| return editErr(e);
    ctx.edit(ed.insertRange(), "\t") catch |e| return editErr(e);
    return ok;
}

// ── Buffers ─────────────────────────────────────────────────────────

fn cBufferNext(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.buffers.switchTo(ctx.gpa, ctx.buffers.nextId(), ctx.head, ctx.keymap);
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

/// Close the active buffer; a dirty buffer refuses (save or use a
/// force-close from config).
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

/// Open a local file in a buffer (existing buffer wins — dedupe by
/// path). The graphical shell rebinds this with a provider-aware,
/// remote-capable version; this core one keeps headless hosts honest.
fn cOpen(ctx: *Context, args: struct { path: []const u8 }) anyerror!Value {
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
    const entry = ctx.buffer();
    const f: facts.Facts = .{
        .path = if (entry.textEditor()) |ed| ed.backingPath() else null,
        .name = entry.name,
        .mode = ctx.head.currentMode(),
        .lang = Actions.langOfName(entry.name),
        .tool = entry.tool,
    };
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
    command.define("buffer-back", "Return to the previously active buffer (tool `q`).", cBufferBack),
    command.define("buffer-switch", "Focus the buffer with the given id.", cBufferSwitch),
    command.define("buffer-create", "Create (and focus) a named scratch buffer.", cBufferCreate),
    command.define("buffer-close", "Close the active buffer (refuses when dirty).", cBufferClose),
    command.define("buffer-read-only", "Set/clear the active buffer's read-only flag.", cBufferReadOnly),
    command.define("open", "Open a file in a buffer (dedupes by path).", cOpen),
    command.define("open-target", "Open and focus a published semantic target.", cOpenTarget),
    command.define("open-relative", "Open a raw name below the semantic working target.", cOpenRelative),
    command.define("selection-copy", "Invoke the focused semantic selection.copy action.", cSelectionCopy),
    command.define("selection-cut", "Invoke the focused semantic selection.cut action.", cSelectionCut),
    command.define("selection-delete", "Invoke the focused semantic selection.delete action.", cSelectionDelete),
    command.define("selection-paste-before", "Invoke the focused semantic selection.paste-before action.", cSelectionPasteBefore),
    command.define("selection-paste-after", "Invoke the focused semantic selection.paste-after action.", cSelectionPasteAfter),
    command.define("target-open-focused", "Invoke the focused semantic target.open action.", cTargetOpenFocused),
    command.define("hierarchy-toggle-expanded", "Invoke the focused semantic hierarchy.toggle-expanded action.", cHierarchyToggleExpanded),
    command.define("hierarchy-step-out", "Invoke the focused semantic target.open-container action.", cHierarchyStepOut),
    command.define("field-edit", "Invoke the focused semantic field.edit action.", cFieldEdit),
    command.define("view-refresh", "Invoke the focused semantic view.refresh action.", cViewRefresh),
    command.define("view-revert", "Invoke the focused semantic view.revert action.", cViewRevert),
    command.define("view-apply", "Invoke the focused semantic view.apply action.", cViewApply),
    command.define("echo", "Show a message on the status line.", cEcho),
    command.define("save-as", "Save to a new path (refuses to clobber an existing file).", cSaveAs),
    command.define("delete-backward", "Delete the selection or the character before the cursor.", cDeleteBackward),
    command.define("delete-forward", "Delete the selection or the character after the cursor.", cDeleteForward),
    command.define("undo", "Undo the newest own edit unit.", cUndo),
    command.define("redo", "Redo the newest undone unit.", cRedo),
    command.define("save-file", "Write the buffer to its file backing (the default `save` provider).", cSaveFile),
    command.define("cursor-left", "Move the cursor one character left.", cCursorLeft),
    command.define("cursor-right", "Move the cursor one character right.", cCursorRight),
    command.define("cursor-up", "Move the cursor up one line.", cCursorUp),
    command.define("cursor-down", "Move the cursor down one line.", cCursorDown),
    command.define("row-down", "Move to the next projection row, on its actionable part.", cRowDown),
    command.define("row-up", "Move to the previous projection row, on its actionable part.", cRowUp),
    command.define("set-mark", "Start a selection at the cursor.", cSetMark),
    command.define("clear-selection", "Drop the selection.", cClearSelection),
    command.define("undo-barrier", "Seal the undo unit; the next edit starts a new one.", cUndoBarrier),
    command.define("set-mode", "Switch the keymap mode.", cSetMode),
    command.define("posture-break-out", "Leave a capture posture for the one it displaced.", cPostureBreakOut),
    command.define("quit", "Exit the editor.", cQuit),
    command.define("insert-newline", "Insert a line break at the cursor.", cInsertNewline),
    command.define("insert-tab", "Insert a tab at the cursor.", cInsertTab),
};

/// Register every built-in and the default keymap. The default mode is
/// plain modeless editing; a config replaces any of it by rebinding.
pub fn install(gpa: std.mem.Allocator, commands: *command.Commands, keymap: *@import("Keymap.zig"), head: *@import("Head.zig"), actions: *@import("action.zig")) !void {
    for (table) |cmd| _ = try commands.bind(gpa, cmd.name, cmd);

    // `save` is an ACTION: `C-s`/`:w`/palette all dispatch it, and a projection
    // (files/git) provides its own `save` scoped to its tool identity, which
    // wins in its buffer. The default provider writes the file backing.
    try command.registerAction(gpa, commands, actions, "save", .pick);
    try actions.provide(.{ .action = "save", .command = "save-file", .owner = "core" });

    // Retiring an entry is an ACTION too, for the same reason `save` is: what a
    // tool's entry is worth is the tool's question. The default provider drops
    // it (refusing an unsaved file); a projection whose text is unrecoverable —
    // a commit draft — provides its own and asks first.
    try command.registerAction(gpa, commands, actions, "close", .pick);
    try actions.provide(.{ .action = "close", .command = "buffer-close", .owner = "core" });

    // Input models express leaving a transient/tool locus as an intent. Vim's
    // `q` is one such mapping; another editor can choose another key, and a
    // more specific provider can override this buffer-history implementation.
    try command.registerAction(gpa, commands, actions, "navigate-back", .pick);
    try actions.provide(.{ .action = "navigate-back", .command = "buffer-back", .owner = "core" });

    // MOVING IN A TOOL ENTRY IS MOVING THE CURSOR.
    //
    // `std.navigation.down`/`up` were only ever answered by the SEMANTIC plane:
    // a scene offered them from its focused node, so a std-only grammar could
    // drive a scene-backed view and nothing else. A tool entry whose view is a
    // text PROJECTION has rows too, and in it "down" is unambiguous — there is
    // no goal column to preserve, because a row is a row.
    //
    // Scoped to `.tool` deliberately. In an ordinary text buffer vertical
    // motion is the GRAMMAR.s (vim.s `motion.down` is goal-column aware over
    // rendered geometry, which `cursor-down` is not), so core answering there
    // would quietly replace it.
    inline for (.{
        .{ "std.navigation.down", "row-down" },
        .{ "std.navigation.up", "row-up" },
    }) |pair| try actions.provide(.{
        .action = pair[0],
        .predicate = .{ .locus = .tool },
        .command = pair[1],
        .owner = "core",
    });

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
