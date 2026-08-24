//! Runtime facade for provider-authored semantic views. The kernel beneath
//! this module is immutable vocabulary; this module owns host-side lifetimes.

const std = @import("std");

pub const field = @import("field.zig");
pub const interaction = @import("interaction.zig");
pub const view = @import("view.zig");

test {
    std.testing.refAllDecls(@This());
}
