//! Built-in commands. Everything user-visible goes through the command
//! ABI — these are ordinary typed functions the same `define` machinery
//! wraps, registered under the same late-binding names a config or
//! plugin may shadow. If a built-in can't live behind this door, the
//! core is wrong (the manifesto's test).

const std = @import("std");

const command = @import("command.zig");
const Context = command.Context;
const Value = command.Value;

const ok: Value = .nil;

fn cInsertText(ctx: *Context, args: struct { text: []const u8 }) anyerror!Value {
    if (ctx.buffer().read_only) return ok;
    try ctx.editor().insertText(ctx.gpa, args.text);
    return ok;
}

fn cDeleteBackward(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (ctx.buffer().read_only) return ok;
    try ctx.editor().deleteBackward(ctx.gpa);
    return ok;
}

fn cDeleteForward(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (ctx.buffer().read_only) return ok;
    try ctx.editor().deleteForward(ctx.gpa);
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

fn cSave(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor().requestSave(ctx.gpa);
    return ok;
}

fn cCursorLeft(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor().moveLeft();
    return ok;
}

fn cCursorRight(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor().moveRight();
    return ok;
}

fn cCursorUp(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor().moveUp();
    return ok;
}

fn cCursorDown(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor().moveDown();
    return ok;
}

fn cLineStart(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor().moveLineStart();
    return ok;
}

fn cLineEnd(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor().moveLineEnd();
    return ok;
}

fn cDocStart(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor().moveDocStart();
    return ok;
}

fn cDocEnd(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor().moveDocEnd();
    return ok;
}

fn cWordForward(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor().moveWordForward(ctx.gpa);
    return ok;
}

fn cWordBackward(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor().moveWordBackward(ctx.gpa);
    return ok;
}

fn cWordEnd(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor().moveWordEnd(ctx.gpa);
    return ok;
}

fn cFirstNonBlank(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor().moveFirstNonBlank(ctx.gpa);
    return ok;
}

fn cMatchBracket(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor().matchBracket(ctx.gpa);
    return ok;
}

fn cJoinLines(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (ctx.buffer().read_only) return ok;
    try ctx.editor().joinLine(ctx.gpa);
    return ok;
}

fn cYankSelection(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor().yankSelection(ctx.gpa);
    ctx.editor().clearSelection();
    return ok;
}

fn cPaste(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (ctx.buffer().read_only) return ok;
    try ctx.editor().paste(ctx.gpa);
    return ok;
}

/// Move to a character on the current line. `to` is the (single) target
/// character; `dir` is "f"/"F" (find, land on it) or "t"/"T" (till, land
/// one short); uppercase means backward.
fn cFindChar(ctx: *Context, args: struct { dir: []const u8, to: []const u8 }) anyerror!Value {
    if (args.to.len == 0 or args.dir.len == 0) return ok;
    const target = args.to[0]; // first byte (ASCII targets)
    const d = args.dir[0];
    const forward = d == 'f' or d == 't';
    const till = d == 't' or d == 'T';
    try ctx.editor().findChar(ctx.gpa, target, forward, till);
    return ok;
}

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

fn cDeleteSelection(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (ctx.buffer().read_only) return ok;
    if (ctx.editor().selectedRange()) |r| try ctx.editor().deleteRange(ctx.gpa, r);
    return ok;
}

fn cSetMode(ctx: *Context, args: struct { mode: []const u8 }) anyerror!Value {
    try ctx.keymap.setMode(ctx.gpa, args.mode);
    return ok;
}

fn cQuit(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.quit.* = true;
    return ok;
}

fn cInsertNewline(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (ctx.buffer().read_only) return ok;
    try ctx.editor().insertText(ctx.gpa, "\n");
    return ok;
}

fn cInsertTab(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (ctx.buffer().read_only) return ok;
    try ctx.editor().insertText(ctx.gpa, "\t");
    return ok;
}

// ── Buffers ─────────────────────────────────────────────────────────

fn cBufferNext(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.buffers.switchTo(ctx.gpa, ctx.buffers.nextId(), ctx.keymap);
    return ok;
}

fn cBufferSwitch(ctx: *Context, args: struct { id: i64 }) anyerror!Value {
    if (args.id < 0) return error.TypeMismatch;
    try ctx.buffers.switchTo(ctx.gpa, @intCast(args.id), ctx.keymap);
    return ok;
}

fn cBufferCreate(ctx: *Context, args: struct { name: []const u8 }) anyerror!Value {
    const id = try ctx.buffers.create(ctx.gpa, args.name);
    try ctx.buffers.switchTo(ctx.gpa, id, ctx.keymap);
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
    try ctx.buffers.close(ctx.gpa, b.id, ctx.keymap);
    return ok;
}

/// Open a local file in a buffer (existing buffer wins — dedupe by
/// path). The graphical shell rebinds this with a provider-aware,
/// remote-capable version; this core one keeps headless hosts honest.
fn cOpen(ctx: *Context, args: struct { path: []const u8 }) anyerror!Value {
    if (ctx.buffers.findByPath(args.path)) |id| {
        try ctx.buffers.switchTo(ctx.gpa, id, ctx.keymap);
        return .{ .integer = @intCast(id) };
    }
    const id = try ctx.buffers.create(ctx.gpa, std.fs.path.basename(args.path));
    const ed = &ctx.buffers.get(id).?.editor;
    ed.openFile(ctx.gpa, args.path) catch |err| switch (err) {
        error.FileNotFound => try ed.adoptPath(ctx.gpa, args.path),
        else => |e| {
            try ctx.buffers.close(ctx.gpa, id, ctx.keymap);
            return e;
        },
    };
    try ctx.buffers.switchTo(ctx.gpa, id, ctx.keymap);
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
    ctx.echo.clearRetainingCapacity();
    try ctx.echo.appendSlice(ctx.gpa, args.text);
    return ok;
}

const table = [_]command.Command{
    command.define("insert-text", "Insert text at the cursor (replaces the selection).", cInsertText),
    command.define("buffer-next", "Focus the next buffer (cyclic).", cBufferNext),
    command.define("buffer-switch", "Focus the buffer with the given id.", cBufferSwitch),
    command.define("buffer-create", "Create (and focus) a named scratch buffer.", cBufferCreate),
    command.define("buffer-close", "Close the active buffer (refuses when dirty).", cBufferClose),
    command.define("buffer-read-only", "Set/clear the active buffer's read-only flag.", cBufferReadOnly),
    command.define("open", "Open a file in a buffer (dedupes by path).", cOpen),
    command.define("echo", "Show a message on the status line.", cEcho),
    command.define("save-as", "Save to a new path (refuses to clobber an existing file).", cSaveAs),
    command.define("delete-backward", "Delete the selection or the character before the cursor.", cDeleteBackward),
    command.define("delete-forward", "Delete the selection or the character after the cursor.", cDeleteForward),
    command.define("delete-selection", "Delete the selected range.", cDeleteSelection),
    command.define("undo", "Undo the newest own edit unit.", cUndo),
    command.define("redo", "Redo the newest undone unit.", cRedo),
    command.define("save", "Request an asynchronous save of the current file.", cSave),
    command.define("cursor-left", "Move the cursor one character left.", cCursorLeft),
    command.define("cursor-right", "Move the cursor one character right.", cCursorRight),
    command.define("cursor-up", "Move the cursor up one line.", cCursorUp),
    command.define("cursor-down", "Move the cursor down one line.", cCursorDown),
    command.define("line-start", "Move to the start of the line.", cLineStart),
    command.define("line-end", "Move to the end of the line.", cLineEnd),
    command.define("doc-start", "Move to the start of the document.", cDocStart),
    command.define("doc-end", "Move to the end of the document.", cDocEnd),
    command.define("word-forward", "Move to the next word start.", cWordForward),
    command.define("word-backward", "Move to the previous word start.", cWordBackward),
    command.define("word-end", "Move to the end of the next word.", cWordEnd),
    command.define("first-non-blank", "Move to the first non-blank on the line.", cFirstNonBlank),
    command.define("match-bracket", "Jump to the matching bracket.", cMatchBracket),
    command.define("join-lines", "Join this line with the next.", cJoinLines),
    command.define("yank-selection", "Copy the selection to the yank register.", cYankSelection),
    command.define("paste", "Insert the yank register at the cursor.", cPaste),
    command.define("find-char", "Move to a character on the line (dir f|F|t|T, to <char>).", cFindChar),
    command.define("set-mark", "Start a selection at the cursor.", cSetMark),
    command.define("clear-selection", "Drop the selection.", cClearSelection),
    command.define("set-mode", "Switch the keymap mode.", cSetMode),
    command.define("quit", "Exit the editor.", cQuit),
    command.define("insert-newline", "Insert a line break at the cursor.", cInsertNewline),
    command.define("insert-tab", "Insert a tab at the cursor.", cInsertTab),
};

/// Register every built-in and the default keymap. The default mode is
/// plain modeless editing; a config replaces any of it by rebinding.
pub fn install(gpa: std.mem.Allocator, commands: *command.Commands, keymap: *@import("Keymap.zig")) !void {
    for (table) |cmd| _ = try commands.bind(gpa, cmd.name, cmd);

    try keymap.setMode(gpa, "default");
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
        .{ "Home", "line-start" },
        .{ "End", "line-end" },
        .{ "C-a", "line-start" },
        .{ "C-e", "line-end" },
        .{ "C-s", "save" },
        .{ "C-z", "undo" },
        .{ "C-y", "redo" },
        .{ "C-space", "set-mark" },
        .{ "C-g", "clear-selection" },
        .{ "C-Right", "word-forward" },
        .{ "C-Left", "word-backward" },
        .{ "C-Home", "doc-start" },
        .{ "C-End", "doc-end" },
        .{ "C-q", "quit" },
        .{ "C-b", "buffers" },
        .{ "C-Tab", "buffer-next" },
    };
    for (binds) |b| try keymap.bind(gpa, "default", b[0], b[1]);
    try keymap.setTextCommand(gpa, "default", "insert-text");

    try @import("pick.zig").install(gpa, commands, keymap);
}

test {
    std.testing.refAllDecls(@This());
}
