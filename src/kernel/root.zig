//! weft-kernel: portable editor/view contracts.
//!
//! This is a real Zig module root. Code outside this directory imports it as
//! `weft_kernel`; it must not reach into `src/kernel/*` by relative path.

pub const schema = @import("weft_schema");
pub const handle = @import("handle.zig");
pub const target = @import("target.zig");
pub const scene = @import("scene.zig");
pub const view = @import("view.zig");
pub const selection = @import("selection.zig");
pub const focus = @import("focus.zig");
pub const transfer = @import("transfer.zig");
pub const interaction = @import("interaction.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
