//! `core` — weft's public ABI. Everything user-visible is built through
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
pub const intentions = @import("intentions.zig");
pub const authority = @import("authority.zig");
pub const wasm = @import("wasm.zig");
pub const wasm_abi = @import("wasm_abi.zig");
pub const wasm_host = @import("wasm_host.zig");
pub const quickjs = @import("quickjs.zig");
pub const task = @import("task.zig");
pub const async_loop = @import("async.zig");
pub const scheduler = @import("scheduler.zig");
pub const kv = @import("kv.zig");
pub const proc = @import("proc.zig");
pub const repl_session = @import("repl_session.zig");
pub const net_session = @import("net_session.zig");
pub const subbuffer = @import("subbuffer.zig");
pub const register = @import("register.zig");
pub const Register = register;
pub const watch = @import("watch.zig");
pub const undo = @import("undo.zig");
pub const UndoLog = undo.UndoLog;
pub const Editor = @import("Editor.zig");
pub const Buffers = @import("Buffers.zig");
pub const Keymap = @import("Keymap.zig");
pub const input = @import("input.zig");
pub const TextCommit = input.TextCommit;
pub const Head = @import("Head.zig");
pub const semantic = @import("semantic.zig");
pub const view_offers = @import("view_offers.zig");
pub const plugin_offers = @import("plugin_offers.zig");
pub const target_open = @import("target_open.zig");
pub const builtins = @import("builtins.zig");
pub const pick = @import("pick.zig");
pub const surface = @import("surface.zig");
pub const fs_source = @import("fs_source.zig");
pub const Mirror = @import("mirror.zig");
pub const syntax = @import("syntax.zig");
pub const syntax_claim = @import("syntax_claim.zig");
pub const markdown = @import("markdown.zig");
// lsp (the client) removed — LSP is the `lsp` wasm plugin (src/guest/lsp.zig),
// a caps provider over the streaming membrane. See [[lsp-plugin-migration]].
pub const position = @import("position.zig");
pub const layers = @import("layers.zig");
pub const embed = @import("embed.zig");
pub const breakpoints = @import("breakpoints.zig");
pub const mode = @import("mode.zig");
pub const facts = @import("facts.zig");
pub const container = @import("container.zig");
pub const catalog = @import("catalog.zig");
pub const Catalog = catalog.Catalog;
pub const intent = @import("intent.zig");
pub const manifest = @import("manifest.zig");
pub const ctx = @import("ctx.zig");
pub const Ctx = ctx.Ctx;
pub const System = @import("System.zig");
pub const inproc = @import("inproc/InProcClient.zig");
pub const InProcClient = inproc.InProcClient;
pub const capability = @import("capability.zig");
pub const Caps = capability.Caps;
pub const Actions = @import("action.zig");
pub const proc_stream = @import("proc_stream.zig");
pub const status_feed = @import("status_feed.zig");
pub const viewport = @import("viewport.zig");
pub const focus_feed = @import("focus_feed.zig");
pub const placement = @import("placement.zig");
pub const complete_ui = @import("complete_ui.zig");
// nav_ui (hover/definition/symbols consumers) removed — moved to the `lsp` plugin.
pub const wire = @import("weft_wire");
pub const secure = @import("secure.zig");
pub const identity = @import("identity.zig");
pub const known_peers = @import("known_peers.zig");
pub const session = @import("session.zig");
pub const hub = @import("hub.zig");
pub const locus = @import("locus.zig");
pub const rooted_fs = @import("rooted_fs.zig");
pub const peer_fs = @import("peer_fs.zig");
pub const net = @import("net.zig");
pub const Pick = pick.Pick;
pub const file = @import("file.zig");
pub const ShellFs = @import("ShellFs.zig");
pub const backing = @import("backing.zig");
pub const Backing = backing.Backing;
pub const textdiff = @import("textdiff.zig");
pub const GraphDoc = @import("graph.zig");
pub const transcript = @import("transcript.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
