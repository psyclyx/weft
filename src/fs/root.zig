//! weft-fs: semantic filesystem service contract.
//!
//! Platform providers import this named module. This module never imports a
//! platform implementation, which keeps the dependency arrow one-way.

pub const semantic = @import("weft_semantic");
pub const contract = @import("contract.zig");
pub const plan = @import("plan.zig");
pub const service = @import("service.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
