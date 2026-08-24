//! Target runtime facade: stable resource descriptions and plugin handler
//! discovery and owner-scoped relation providers. Neither module assumes a
//! local path or a text buffer.

const std = @import("std");

pub const resolver = @import("resolver.zig");
pub const relation = @import("relation.zig");
pub const target = @import("target.zig");

test {
    std.testing.refAllDecls(@This());
}
