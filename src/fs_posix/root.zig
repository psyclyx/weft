//! POSIX (Linux + macOS) filesystem provider module facade.
//!
//! Platform mechanism lives in `provider.zig` (portable libc) and
//! `stat.zig` (the one per-OS fork); this root exports only the provider type
//! intended for consumers. Provider conformance tests compile through this
//! same facade.

const implementation = @import("provider.zig");

/// The app-facing name build.zig's provider selection keeps stable across
/// hosts. The POSIX-specific alias stays available to focused tests.
pub const Provider = implementation.PosixFs;
pub const PosixFs = Provider;

test {
    _ = implementation;
}
