//! e2e — the headless end-to-end suite root. Drives the full editor the way a
//! person does (boot the real config, press keys through the keymap, observe the
//! rendered surface + disk) and treats every rough edge as SIGNAL to fix, not to
//! test around. The shared driver is `harness.zig`; the per-concern test files
//! below are pulled in here so `src/tests.zig` need only reference this root.
//!
//! STILL-OPEN gaps (fix + promote into a granular test as each gains its piece):
//!   • debugger — no debug/DAP plugin or `debug-*` commands, so "set a breakpoint
//!     and step" has no keys to press (the biggest missing IDE capability).
//!   • full collab frame-loop path — the loopback exercises the session/Collab
//!     sync layer directly; wrapping it in collab.tickCollab (hub multi-peer
//!     adoption, partial checkout, reconnect) needs the ShareCtx + main() locals
//!     stood up headlessly.

test {
    _ = @import("editing_test.zig");
    _ = @import("window_test.zig");
    _ = @import("collab_test.zig");
    _ = @import("project_test.zig");
    _ = @import("config_test.zig");
    _ = @import("authoring_test.zig");
    _ = @import("teardown_test.zig");
}
