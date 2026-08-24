//! Built-in commands. Everything user-visible goes through the command
//! ABI — these are ordinary typed functions the same `define` machinery
//! wraps, registered under the same late-binding names a config or
//! plugin may shadow. If a built-in can't live behind this door, the
//! core is wrong (the manifesto's test).

const std = @import("std");

const command = @import("command.zig");
const Context = command.Context;
const Value = command.Value;
const facts = @import("facts.zig");
const container_mod = @import("container.zig");
const Actions = @import("action.zig");

const ok: Value = .nil;

fn semanticFieldInput(ctx: *Context, input: @import("semantic.zig").Services.FieldInput) !bool {
    const services = ctx.semantic orelse return false;
    return services.inputFocusedField(ctx.head, ctx.gpa, input);
}

fn semanticMove(ctx: *Context, movement: @import("weft_kernel").focus.Movement) !bool {
    const services = ctx.semantic orelse return false;
    return services.moveHeadFocus(ctx.head, ctx.gpa, movement);
}

/// Map an edit refusal to a visible status echo. Keymap dispatch only
/// `log.warn`s command errors, so a grade refusal would be silent; surface
/// it honestly and swallow it (a `view` peer editing is not an error, just
/// not allowed). Other errors propagate.
fn editErr(ctx: *Context, e: anyerror) anyerror!Value {
    if (e != error.Unauthorized) return e;
    ctx.head.echo.clearRetainingCapacity();
    try ctx.head.echo.appendSlice(ctx.gpa, "read-only: view access");
    return ok;
}

fn cInsertText(ctx: *Context, args: struct { text: []const u8 }) anyerror!Value {
    if (try semanticFieldInput(ctx, .{ .replace_selection = args.text })) return ok;
    if (ctx.buffer().read_only) return ok;
    ctx.edit(ctx.editor().insertRange(), args.text) catch |e| return editErr(ctx, e);
    return ok;
}

fn cDeleteBackward(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticFieldInput(ctx, .delete_previous)) return ok;
    if (ctx.buffer().read_only) return ok;
    const r = ctx.editor().backspaceRange() orelse return ok;
    ctx.edit(r, "") catch |e| return editErr(ctx, e);
    return ok;
}

fn cDeleteForward(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticFieldInput(ctx, .delete_next)) return ok;
    if (ctx.buffer().read_only) return ok;
    const r = ctx.editor().forwardRange() orelse return ok;
    ctx.edit(r, "") catch |e| return editErr(ctx, e);
    return ok;
}

fn cUndo(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return .{ .boolean = try ctx.editor().undo(ctx.gpa) };
}

fn cRedo(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return .{ .boolean = try ctx.editor().redo(ctx.gpa) };
}

/// The default `save` provider: write the buffer to its file backing. `save` is
/// an ACTION (not a bare command), so a projection (dired/magit) registers its
/// own `save` provider scoped to its tool identity — the action system picks it
/// over this in the projection's buffer, by specificity. The core stays
/// projection-agnostic: no `if (isTool)` branch lives here.
fn cSaveFile(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor().requestSave(ctx.gpa);
    return ok;
}

fn cCursorLeft(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticFieldInput(ctx, .move_previous)) return ok;
    ctx.editor().moveLeft();
    return ok;
}

fn cCursorRight(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticFieldInput(ctx, .move_next)) return ok;
    ctx.editor().moveRight();
    return ok;
}

fn cCursorUp(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticMove(ctx, .previous)) return ok;
    ctx.editor().moveUp();
    return ok;
}

fn cCursorDown(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticMove(ctx, .next)) return ok;
    ctx.editor().moveDown();
    return ok;
}

// Word/WORD/line/doc motions and match-bracket moved to the `motions` plugin
// (design §6.1 — they return a `range` an operator awaits). Core keeps only the
// grapheme/line step primitive (`editor.step`, exposed via cursor-*) and the
// selection write-half (set-mark/clear-selection) below.

fn cSetMark(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor().setMark(ctx.gpa);
    return ok;
}

fn cClearSelection(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor().clearSelection();
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
    ctx.editor().history.barrier();
    return ok;
}

fn cSetMode(ctx: *Context, args: struct { mode: []const u8 }) anyerror!Value {
    // A locked projection mode (magit/git-view) refuses to switch to a different
    // editing mode — the read-only-buffer mode pin (see Keymap.mayLeaveLocked).
    if (!ctx.keymap.mayLeaveLocked(ctx.head.currentMode(), args.mode)) return ok;
    // THE POLICY DOOR (task #19 item 3): this is a bound command handler —
    // it HAS a live `*command.Context`, so it captures a `Ctx` and changes
    // mode through `Ctx.setMode`, not the raw `Head.setModeRaw` mechanism.
    try ctx.capturedCtx().setMode(args.mode);
    return ok;
}

fn cQuit(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.quit.* = true;
    return ok;
}

fn cInsertNewline(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticFieldInput(ctx, .{ .replace_selection = "\n" })) return ok;
    if (ctx.buffer().read_only) return ok;
    ctx.edit(ctx.editor().insertRange(), "\n") catch |e| return editErr(ctx, e);
    return ok;
}

fn cInsertTab(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (try semanticFieldInput(ctx, .{ .replace_selection = "\t" })) return ok;
    if (ctx.buffer().read_only) return ok;
    ctx.edit(ctx.editor().insertRange(), "\t") catch |e| return editErr(ctx, e);
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
fn cBufferClose(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    const b = ctx.buffer();
    if (b.editor.isDirty(ctx.gpa) catch true) return .{ .string = "dirty" };
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
    const ed = &ctx.buffers.get(id).?.editor;
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

/// Re-point the buffer at a new local path and save. Refuses to
/// clobber an existing file (create-guarded) — open it instead if you
/// mean to overwrite its history.
fn cSaveAs(ctx: *Context, args: struct { path: []const u8 }) anyerror!Value {
    const ed = ctx.editor();
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
        .shell, .tool => return .{ .string = "unsupported backing for save-as" },
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

/// `explain-binding <slot>` — the Container's `explain` (north-star-plan
/// §2.2/§6 W1) wired to a REAL consumer, not a debug printf: echoes which
/// bindings on an ACTION slot are eligible for the active buffer's facts and
/// why the winner won. The facts mirror `Context.actionCtx` (same
/// mode/lang/tool) plus the buffer's path/name, so `explain-binding eval`
/// answers exactly the question `Actions.resolve("eval", ...)` would have
/// asked.
fn cExplainBinding(ctx: *Context, args: struct { slot: []const u8 }) anyerror!Value {
    const f: facts.Facts = .{
        .path = ctx.editor().backingPath(),
        .name = ctx.buffers.active().name,
        .mode = ctx.head.currentMode(),
        .lang = Actions.langOfName(ctx.buffers.active().name),
        .tool = ctx.editor().toolName() orelse "",
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
    command.define("set-mark", "Start a selection at the cursor.", cSetMark),
    command.define("clear-selection", "Drop the selection.", cClearSelection),
    command.define("undo-barrier", "Seal the undo unit; the next edit starts a new one.", cUndoBarrier),
    command.define("set-mode", "Switch the keymap mode.", cSetMode),
    command.define("quit", "Exit the editor.", cQuit),
    command.define("insert-newline", "Insert a line break at the cursor.", cInsertNewline),
    command.define("insert-tab", "Insert a tab at the cursor.", cInsertTab),
};

/// Register every built-in and the default keymap. The default mode is
/// plain modeless editing; a config replaces any of it by rebinding.
pub fn install(gpa: std.mem.Allocator, commands: *command.Commands, keymap: *@import("Keymap.zig"), head: *@import("Head.zig"), actions: *@import("action.zig")) !void {
    for (table) |cmd| _ = try commands.bind(gpa, cmd.name, cmd);

    // `save` is an ACTION: `C-s`/`:w`/palette all dispatch it, and a projection
    // (dired/magit) provides its own `save` scoped to its tool identity, which
    // wins in its buffer. The default provider writes the file backing.
    try command.registerAction(gpa, commands, actions, "save", .pick);
    try actions.provide(.{ .action = "save", .command = "save-file", .owner = "core" });

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
        .{ "Return", "insert-newline" },
        .{ "KP_Enter", "insert-newline" },
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
    try keymap.setTextCommand(gpa, "default", "insert-text");

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

    // A second, higher-priority "save" provider (as a projection like dired
    // would register), so `explain-binding` has more than one eligible
    // binding to report on.
    try actions.provide(.{ .action = "save", .command = "dired-save", .priority = 10, .owner = "dired" });

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
    try t.expect(std.mem.indexOf(u8, head.echo.items, "dired-save") != null);
    try t.expect(std.mem.indexOf(u8, head.echo.items, "2 eligible") != null);

    // An unknown slot: no eligible bindings, no crash, an honest echo.
    _ = try command.run(&commands, &ctx, "explain-binding", &.{.{ .string = "nonexistent-slot" }});
    try t.expect(std.mem.indexOf(u8, head.echo.items, "no eligible binding") != null);
}

test {
    std.testing.refAllDecls(@This());
}
