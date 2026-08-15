//! `core` — scion's public ABI. Everything user-visible is built through
//! this module: built-in features are clients of the same surface plugins
//! get. The pieces:
//!
//! - `Document`: a buffer as a CRDT replica; every mutator is a peer.
//! - `patch`: composed edit patches (the commit-log currency).
//! - `registry`: late-binding names.
//! - `command`: typed commands over a portable value ABI.
//! - `task`: off-hot-path work with poll-only completion.

pub const Document = @import("Document.zig");
pub const patch = @import("patch.zig");
pub const Patch = patch.Patch;
pub const registry = @import("registry.zig");
pub const Registry = registry.Registry;
pub const command = @import("command.zig");
pub const Command = command.Command;
pub const task = @import("task.zig");
pub const undo = @import("undo.zig");
pub const UndoLog = undo.UndoLog;
pub const Editor = @import("Editor.zig");
pub const Buffers = @import("Buffers.zig");
pub const Keymap = @import("Keymap.zig");
pub const builtins = @import("builtins.zig");
pub const plugin = @import("plugin.zig");
pub const Plugin = plugin.Plugin;
pub const pick = @import("pick.zig");
pub const fs_source = @import("fs_source.zig");
pub const Mirror = @import("mirror.zig");
pub const syntax = @import("syntax.zig");
pub const lsp = @import("lsp.zig");
pub const position = @import("position.zig");
pub const layers = @import("layers.zig");
pub const capability = @import("capability.zig");
pub const Caps = capability.Caps;
pub const complete_ui = @import("complete_ui.zig");
pub const nav_ui = @import("nav_ui.zig");
pub const wire = @import("wire.zig");
pub const secure = @import("secure.zig");
pub const session = @import("session.zig");
pub const Pick = pick.Pick;
pub const file = @import("file.zig");
pub const ShellFs = @import("ShellFs.zig");
pub const backing = @import("backing.zig");
pub const Backing = backing.Backing;

test {
    @import("std").testing.refAllDecls(@This());
}
