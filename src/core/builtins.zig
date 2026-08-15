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
    try ctx.editor.insertText(ctx.gpa, args.text);
    return ok;
}

fn cDeleteBackward(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor.deleteBackward(ctx.gpa);
    return ok;
}

fn cDeleteForward(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor.deleteForward(ctx.gpa);
    return ok;
}

fn cUndo(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return .{ .boolean = try ctx.editor.undo(ctx.gpa) };
}

fn cRedo(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return .{ .boolean = try ctx.editor.redo(ctx.gpa) };
}

fn cSave(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor.requestSave(ctx.gpa);
    return ok;
}

fn cCursorLeft(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor.moveLeft();
    return ok;
}

fn cCursorRight(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor.moveRight();
    return ok;
}

fn cCursorUp(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor.moveUp();
    return ok;
}

fn cCursorDown(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor.moveDown();
    return ok;
}

fn cLineStart(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor.moveLineStart();
    return ok;
}

fn cLineEnd(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor.moveLineEnd();
    return ok;
}

fn cDocStart(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor.moveDocStart();
    return ok;
}

fn cDocEnd(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor.moveDocEnd();
    return ok;
}

fn cWordForward(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor.moveWordForward(ctx.gpa);
    return ok;
}

fn cWordBackward(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor.moveWordBackward(ctx.gpa);
    return ok;
}

fn cSetMark(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor.setMark(ctx.gpa);
    return ok;
}

fn cClearSelection(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.editor.clearSelection();
    return ok;
}

fn cDeleteSelection(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (ctx.editor.selectedRange()) |r| try ctx.editor.deleteRange(ctx.gpa, r);
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
    try ctx.editor.insertText(ctx.gpa, "\n");
    return ok;
}

fn cInsertTab(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    try ctx.editor.insertText(ctx.gpa, "\t");
    return ok;
}

const table = [_]command.Command{
    command.define("insert-text", "Insert text at the cursor (replaces the selection).", cInsertText),
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
    };
    for (binds) |b| try keymap.bind(gpa, "default", b[0], b[1]);
}

test {
    std.testing.refAllDecls(@This());
}
