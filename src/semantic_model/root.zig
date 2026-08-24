//! weft-semantic: portable editor/view contracts.
//!
//! This is a real Zig module root. Code outside this directory imports it as
//! `weft_semantic`; it must not reach into `src/semantic_model/*` by relative
//! path.

pub const schema = @import("weft_schema");
pub const handle = @import("handle.zig");
pub const owner = @import("owner.zig");
pub const target = @import("target.zig");
pub const scene = @import("scene.zig");
pub const view = @import("view.zig");
pub const selection = @import("selection.zig");
pub const focus = @import("focus.zig");
pub const transfer = @import("transfer.zig");
pub const interaction = @import("interaction.zig");
pub const action = @import("action.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
