//! `core` — weft's public ABI. Everything user-visible is built through
//! this module: built-in features are clients of the same surface plugins
//! get. The pieces:
//!
//! - `Document`: a buffer as a CRDT replica; every mutator is a peer.
//! - `command`: typed commands over a portable value ABI.
//! - `task`: off-hot-path work with poll-only completion.
//!
//! **This list is the ABI, not a catalogue of the directory.** It used to be
//! both: 96 decls, 34 of which no caller anywhere named, re-exported purely
//! because they were files under `core/`. Those files did not go anywhere —
//! they are reached the way any implementation detail is, by the core files
//! that use them — they just stopped claiming to be public. Two of the 34 were
//! different and are called out at their declarations below.

pub const Document = @import("Document.zig");
pub const command = @import("command.zig");
pub const wasm = @import("wasm.zig");
pub const wasm_abi = @import("wasm_abi.zig");
pub const wasm_host = @import("wasm_host.zig");
pub const quickjs = @import("quickjs.zig");
pub const task = @import("task.zig");
pub const async_loop = @import("async.zig");
pub const scheduler = @import("scheduler.zig");
pub const kv = @import("kv.zig");
pub const kv_file = @import("kv_file.zig");
pub const proc = @import("proc.zig");
pub const subbuffer = @import("subbuffer.zig");
pub const register = @import("register.zig");
/// BUILT AHEAD, NOT YET WIRED. The local tier of `fs.watch` (inotify): 387
/// lines, 3 tests, and nothing in this tree calls it — core does not import it
/// and no consumer names `core.watch`. It stays exported because this line is
/// its ONLY reachability: prune it and the code and its tests leave the build
/// entirely. Kept visible rather than quietly dropped, because "unwired" and
/// "unwanted" are different claims and only the author can make the second.
pub const watch = @import("watch.zig");
pub const Editor = @import("Editor.zig");
pub const Buffers = @import("Buffers.zig");
/// The compact editor environment core's own tests run against. Exported
/// because a cross-layer test — one that drives core's membrane through app's
/// keypress path, so it can live in neither — needs to build the same `Context`
/// core's tests do rather than hand-roll a fourth copy of it.
pub const TestHost = @import("TestHost.zig");
pub const Keymap = @import("Keymap.zig");
pub const input = @import("weft_input");
pub const TextCommit = input.TextCommit;
pub const Head = @import("Head.zig");
pub const semantic = @import("semantic.zig");
pub const target_open = @import("target_open.zig");
pub const builtins = @import("builtins.zig");
pub const pick = @import("pick.zig");
pub const surface = @import("surface.zig");
pub const fs_source = @import("fs_source.zig");
pub const syntax = @import("syntax.zig");
pub const markdown = @import("markdown.zig");
// lsp (the client) removed — LSP is the `lsp` wasm plugin (src/plugins/lsp/root.zig),
// a caps provider over the streaming membrane. See [[lsp-plugin-migration]].
pub const position = @import("position.zig");
pub const layers = @import("layers.zig");
/// A node tree rendered into a text buffer, with the host owning every
/// offset — the primitive every tool projection was hand-rolling.
pub const projection = @import("projection.zig");
pub const action_offers = @import("action_offers.zig");
/// The one context vocabulary and its predicate — shared with every guest as
/// the `weft_facts` module, re-exported here so host-side consumers name it
/// through core like every other core type.
pub const facts = @import("weft_facts");
/// BUILT AHEAD, NOT YET WIRED — same as `watch` above. Render-embeds
/// (contextual-workspace-architecture §11.8): 831 lines, 9 tests, no caller.
pub const embed = @import("embed.zig");
pub const breakpoints = @import("breakpoints.zig");
pub const container = @import("container.zig");
pub const catalog = @import("catalog.zig");
pub const intent = @import("intent.zig");
pub const manifest = @import("manifest.zig");
pub const ctx = @import("ctx.zig");
pub const System = @import("System.zig");
pub const InProcClient = @import("inproc/InProcClient.zig").InProcClient;
pub const capability = @import("capability.zig");
pub const Caps = capability.Caps;
pub const status_feed = @import("status_feed.zig");
pub const viewport = @import("viewport.zig");
pub const focus_feed = @import("focus_feed.zig");
pub const placement = @import("placement.zig");
pub const complete_ui = @import("complete_ui.zig");
// nav_ui (hover/definition/symbols consumers) removed — moved to the `lsp` plugin.
pub const secure = @import("secure.zig");
pub const identity = @import("identity.zig");
pub const known_peers = @import("known_peers.zig");
pub const grants = @import("grants.zig");
pub const session = @import("session.zig");
pub const hub = @import("hub.zig");
pub const place = @import("place.zig");
/// The membrane import tables, exported so a gate can compare the two
/// surfaces as DATA rather than by scraping their source text.
pub const membrane = struct {
    pub const wl = @import("weft_membrane");
    pub const qjs = @import("membrane/qjs_contract.zig");
    /// `wl`'s data table zipped with the handlers it binds — the gate that
    /// proves the two planes share a door needs the function POINTER, not just
    /// the arity (doc/place.md §4.1a).
    pub const wl_bound = @import("membrane/contract.zig");
};
pub const Place = place.Place;
pub const rooted_fs = @import("rooted_fs.zig");
pub const peer_fs = @import("peer_fs.zig");
pub const Pick = pick.Pick;
pub const file = @import("file.zig");
pub const ShellFs = @import("ShellFs.zig");

test {
    @import("std").testing.refAllDecls(@This());
    // Files whose tests `refAllDecls` alone does not reach — they were listed
    // in src/weft.zig's test block while core was compiled into that module.
    // Core is its own module now, and a module owns its tests.
    _ = @import("target_open.zig");
    _ = @import("intentions.zig");
    _ = @import("tests.zig");
    _ = @import("markdown.zig");
    _ = @import("identity.zig");
    _ = @import("weft_facts");
    _ = @import("container.zig");
}
