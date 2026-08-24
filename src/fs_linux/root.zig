//! Linux filesystem provider module facade.
//!
//! Platform mechanism lives in `provider.zig`; this root exports only the
//! provider type intended for consumers. Provider conformance tests compile
//! through this same facade.

const implementation = @import("provider.zig");

pub const LinuxFs = implementation.LinuxFs;

test {
    _ = implementation;
}
