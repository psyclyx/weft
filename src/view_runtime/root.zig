//! Runtime facade for provider-authored semantic views. `weft_semantic` is
//! immutable vocabulary; this module owns host-side lifetimes.

const std = @import("std");

pub const field = @import("field.zig");
pub const action = @import("action.zig");
pub const interaction = @import("interaction.zig");
pub const view = @import("view.zig");
pub const offers = @import("offers.zig");

test {
    std.testing.refAllDecls(@This());
}
