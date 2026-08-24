//! Linux filesystem provider module facade.
//!
//! Platform mechanism lives in `provider.zig`; this root exports only the
//! provider type intended for consumers. Provider conformance tests compile
//! through this same facade.

const implementation = @import("provider.zig");

/// The app-facing name remains stable when build.zig selects a future Darwin
/// implementation. The Linux-specific alias stays available to focused tests.
pub const Provider = implementation.LinuxFs;
pub const LinuxFs = Provider;

test {
    _ = implementation;
}
