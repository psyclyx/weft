//! weft-fs-remote: a transport-neutral remote implementation of `weft_fs`.
//!
//! The provider and server exchange bounded canonical values. Handles are
//! translated at the membrane: the wire authority is never installed in a
//! local router, and neither endpoint interprets paths or filenames.

pub const protocol = @import("protocol.zig");

pub const Access = protocol.Access;
pub const Exchange = protocol.Exchange;
pub const Provider = protocol.Provider;
pub const Server = protocol.Server;

test {
    @import("std").testing.refAllDecls(@This());
}
