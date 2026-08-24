//! weft-fs: semantic filesystem service contract.
//!
//! Platform providers import this named module. This module never imports a
//! platform implementation, which keeps the dependency arrow one-way.

pub const semantic = @import("weft_semantic");
pub const contract = @import("contract.zig");
pub const action = @import("action.zig");
pub const plan = @import("plan.zig");
pub const service = @import("service.zig");
pub const target = @import("target.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
