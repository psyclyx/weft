// config/agent-ux.js — a minimal SECOND system (north-star-plan §6 W2b gate).
//
// This is NOT loaded by config.js's weft.plugin/weft.use chain — it is a
// standalone manifest, evaluated into its OWN `core.System` exactly the way
// config.js is evaluated into the editor system's (see `core/System.zig`'s
// `applyManifest` and its gate test "a real agent-ux.js manifest hosts a
// second system end-to-end"). "Hosting a second system" (§2.3) is just this:
// evaluate a second manifest into a second bundle — no `weft.system(...)`
// sub-DSL exists yet (that would be a membrane/quickjs host-import change,
// out of W2b's scope — see doc/north-star-config.js's commented sketch of
// what that would eventually look like).
//
// Deliberately minimal — "a few binds, no heavy plugins" (the task's words):
// this file exists to prove the SWAP/HOST mechanism, not to build a real
// agent UX (that's W5's transcript-as-graph-doc work, and W6's check-in).
// A head that `system-swap`s onto "agent-ux" gets THIS keymap/echo, live —
// see `core/System.zig`'s `Host.swap` gate test for the re-bind itself.

weft.bind("normal", "q", "agent-ux-quit");
weft.bind("normal", "SPC a s", "agent-ux-status");
weft.echo("agent-ux: minimal system loaded");
