//! Cross-cutting command registration pulled out of `main()`. These helpers
//! bind sequences of commands that span more than one concern module (the
//! capability-consumer UIs, the cursor/which-key/menu commands) onto the
//! command surface. `main()` keeps ownership of every `var` they point at;
//! these only run the mechanical `commands.bind` sequences, in the same
//! order they had inline (registration is last-wins — order is load-bearing).

const std = @import("std");
const core = @import("weft_core");
const cursor_config = @import("cursor_config.zig");
const dispatch = @import("dispatch.zig");
const providers = @import("providers.zig");

/// Bind the capability consumers (complete) plus the data-driven grammar registry
/// (grammar-add) onto `commands`. Each UI/registry is caller-owned (declared in
/// `main()` with its own defer); this only wires the command specs, in
/// registration order. hover / goto-definition / references / symbols / rename /
/// format / diagnostics / completion are all the `lsp` PLUGIN's now — the only
/// capability consumer left in core is the completion UI, and server commands are
/// config, not a registry.
pub fn registerCapabilityConsumers(
    gpa: std.mem.Allocator,
    commands: *core.command.Commands,
    completion_ui: *core.complete_ui.CompletionUi,
    grammars: *core.syntax.Runtime,
) !void {
    _ = try commands.bind(gpa, "complete.show", completion_ui.commandSpec());
    // Grammars are data: builtins seeded, config extends via command.
    _ = try commands.bind(gpa, "syntax.add-grammar", providers.grammarAddCommand(grammars));
}

const reg_arg: core.command.ArgSpec = .{ .name = "register", .type = .string, .optional = true };
const count_arg: core.command.ArgSpec = .{ .name = "count", .type = .nil, .optional = true };
const macro_cmds = [_]core.command.Command{
    .{ .name = "macro.record-start", .summary = "Start recording your keystrokes into a named macro register.", .args = &.{.{ .name = "register", .type = .string }}, .handler = dispatch.macroRecordStartHandler, .meta = .{ .label = "Record Macro", .menu = "Edit/Macros", .group = "record", .order = 10, .icon = "circle-dot", .prompts = true } },
    .{ .name = "macro.record-stop", .summary = "Stop recording and file the macro under its register.", .args = &.{}, .handler = dispatch.macroRecordStopHandler, .meta = .{ .label = "Stop Recording", .menu = "Edit/Macros", .group = "record", .order = 20, .icon = "stop" } },
    .{ .name = "macro.record-toggle", .summary = "Start recording a macro, into register @ unless one is given, or stop recording.", .args = &.{reg_arg}, .handler = dispatch.macroRecordToggleHandler, .meta = .{ .label = "Toggle Macro Recording", .menu = "Edit/Macros", .group = "record", .order = 30 } },
    .{ .name = "macro.play", .summary = "Replay a macro, the last one played unless a register is given, a count of times.", .args = &.{ reg_arg, count_arg }, .handler = dispatch.macroPlayHandler, .meta = .{ .label = "Play Macro", .menu = "Edit/Macros", .group = "play", .order = 10, .icon = "play" } },
};

/// Bind the caret/which-key/menu commands, registered before the config runs
/// so it can set per-mode styles at load time. `cursor_cfg` and the
/// `which_key_now` flag are caller-owned; `which-key.show` and `mode.leave-menu`
/// use the dispatch handlers, `cursor.set-style`/`cursor.set-blink` the cursor-config
/// ones.
pub fn registerCursorCommands(
    gpa: std.mem.Allocator,
    commands: *core.command.Commands,
    cursor_cfg: *cursor_config.CursorConfig,
    which_key_now: *bool,
) !void {
    _ = try commands.bind(gpa, "mode.leave-menu", .{
        .name = "mode.leave-menu",
        .summary = "Leave a menu and return to the mode it was opened from.",
        .args = &.{},
        .handler = dispatch.menuEscapeHandler,
        .data = null,
        .meta = .{ .internal = true },
    });
    // Dot-repeat: replay the last change's keystrokes (vim `.`). The recorder
    // lives in dispatch (it records through the one keypress interface), so this
    // composes with every plugin out of the box.
    _ = try commands.bind(gpa, "edit.repeat", .{
        .name = "edit.repeat",
        .summary = "Repeat the last change.",
        .args = &.{},
        .handler = dispatch.repeatChangeHandler,
        .data = null,
        .meta = .{ .label = "Repeat Last Change", .menu = "Edit", .group = "history", .order = 30, .icon = "history" },
    });
    // Macros: record the keystroke stream into a named register and replay
    // it, through the same dispatch (`dispatch.zig`'s macro section). Which
    // keys start, stop and play them is the grammar's.
    for (macro_cmds) |cmd| _ = try commands.bind(gpa, cmd.name, cmd);
    // which-key: show the hint popup immediately (bypass the idle delay). If not
    // already in a menu, open the leader menu — so a help key (F1) surfaces it
    // from anywhere.
    _ = try commands.bind(gpa, "which-key.show", .{
        .name = "which-key.show",
        .summary = "Show the key hints now, opening the leader menu when no menu is open.",
        .args = &.{},
        .handler = dispatch.whichKeyNowHandler,
        .data = which_key_now,
        .meta = .{ .label = "Show Key Hints", .menu = "Help", .group = "keys", .order = 10, .icon = "keyboard" },
    });
    _ = try commands.bind(gpa, "cursor.set-style", .{
        .name = "cursor.set-style",
        .summary = "Set a mode's caret style: block, bar or underline.",
        .args = &.{ .{ .name = "mode", .type = .string }, .{ .name = "style", .type = .string } },
        .handler = cursor_config.setCursorHandler,
        .data = cursor_cfg,
        .meta = .{ .internal = true },
    });
    _ = try commands.bind(gpa, "cursor.set-place", .{
        .name = "cursor.set-place",
        .summary = "Set whether a mode draws the caret at the selection's head or inside it on its last character.",
        .args = &.{ .{ .name = "mode", .type = .string }, .{ .name = "place", .type = .string } },
        .handler = cursor_config.cursorPlaceHandler,
        .data = cursor_cfg,
        .meta = .{ .internal = true },
    });
    _ = try commands.bind(gpa, "cursor.set-blink", .{
        .name = "cursor.set-blink",
        .summary = "Turn caret blinking on or off for a mode.",
        .args = &.{ .{ .name = "mode", .type = .string }, .{ .name = "state", .type = .string } },
        .handler = cursor_config.cursorBlinkHandler,
        .data = cursor_cfg,
        .meta = .{ .internal = true },
    });
}
