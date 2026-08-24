//! weft-fs-runtime: authority-scoped routing over filesystem providers.
//!
//! This root is deliberately only a facade. The module depends on the named
//! `weft_kernel` and `weft_fs` contracts; platform providers remain outside.

pub const router = @import("router.zig");

pub const Error = router.Error;
pub const Router = router.Router;

test {
    @import("std").testing.refAllDecls(@This());
}
