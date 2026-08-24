//! Host-side adapters for behavior supplied by sandboxed semantic plugins.
//!
//! This module knows the portable semantic values and narrow view-runtime contracts,
//! but no wasm implementation, editor model, tool kind, or filesystem policy.
//! Transports provide callbacks; registries retain generation-checked endpoints.

const std = @import("std");

pub const field = @import("field.zig");
pub const action = @import("action.zig");

test {
    std.testing.refAllDecls(@This());
}
