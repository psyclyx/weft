//! weft-fs-runtime: authority-scoped routing over filesystem providers.
//!
//! This root is deliberately only a facade. The module depends on the named
//! `weft_semantic` and `weft_fs` contracts; platform providers remain outside.

pub const router = @import("router.zig");
pub const publication = @import("publication.zig");

pub const Error = router.Error;
pub const Router = router.Router;
pub const TargetBinding = router.TargetBinding;

test {
    @import("std").testing.refAllDecls(@This());
}
