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
    _ = try commands.bind(gpa, "complete", completion_ui.commandSpec());
    // Grammars are data: builtins seeded, config extends via command.
    _ = try commands.bind(gpa, "grammar-add", providers.grammarAddCommand(grammars));
}

/// Bind the caret/which-key/menu commands, registered before the config runs
/// so it can set per-mode styles at load time. `cursor_cfg` and the
/// `which_key_now` flag are caller-owned; `which-key-now` and `menu-escape`
/// use the dispatch handlers, `set-cursor`/`cursor-blink` the cursor-config
/// ones.
pub fn registerCursorCommands(
    gpa: std.mem.Allocator,
    commands: *core.command.Commands,
    cursor_cfg: *cursor_config.CursorConfig,
    which_key_now: *bool,
) !void {
    _ = try commands.bind(gpa, "menu-escape", .{
        .name = "menu-escape",
        .summary = "Leave a menu, back to its return mode.",
        .args = &.{},
        .handler = dispatch.menuEscapeHandler,
        .data = null,
    });
    // Dot-repeat: replay the last change's keystrokes (vim `.`). The recorder
    // lives in dispatch (it records through the one keypress interface), so this
    // composes with every plugin out of the box.
    _ = try commands.bind(gpa, "repeat-change", .{
        .name = "repeat-change",
        .summary = "Repeat the last change (vim `.`).",
        .args = &.{},
        .handler = dispatch.repeatChangeHandler,
        .data = null,
    });
    // which-key: show the hint popup immediately (bypass the idle delay). If not
    // already in a menu, open the leader menu — so a help key (F1) surfaces it
    // from anywhere.
    _ = try commands.bind(gpa, "which-key-now", .{
        .name = "which-key-now",
        .summary = "Show the which-key popup now (open the leader menu if idle).",
        .args = &.{},
        .handler = dispatch.whichKeyNowHandler,
        .data = which_key_now,
    });
    _ = try commands.bind(gpa, "set-cursor", .{
        .name = "set-cursor",
        .summary = "Set the caret style (block|bar|underline) for a mode.",
        .args = &.{ .{ .name = "mode", .type = .string }, .{ .name = "style", .type = .string } },
        .handler = cursor_config.setCursorHandler,
        .data = cursor_cfg,
    });
    _ = try commands.bind(gpa, "cursor-blink", .{
        .name = "cursor-blink",
        .summary = "Toggle caret blink (on|off) for a mode.",
        .args = &.{ .{ .name = "mode", .type = .string }, .{ .name = "state", .type = .string } },
        .handler = cursor_config.cursorBlinkHandler,
        .data = cursor_cfg,
    });
}
