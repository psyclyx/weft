//! entropy — the OS CSPRNG, for minting keys and identities without `std.Io`
//! plumbing (the callers mint at init and in tests, where no `Io` is in hand).
//!
//! libc, so one spelling serves every host: `arc4random_buf` wherever libc has
//! it (Darwin always; glibc >= 2.36, where it is a getrandom wrapper), else
//! `getrandom(2)` (older glibc, musl). Both draw from the kernel CSPRNG and
//! neither can fail once the pool is initialised; a failing `getrandom` is a
//! broken host, not a recoverable condition, so it panics.

const std = @import("std");
const c = std.c;

/// Fill `buf` with cryptographically secure random bytes.
pub fn fill(buf: []u8) void {
    if (@TypeOf(c.arc4random_buf) != void) return c.arc4random_buf(buf.ptr, buf.len);
    var got: usize = 0;
    while (got < buf.len) {
        const rc = c.getrandom(buf[got..].ptr, buf.len - got, 0);
        switch (c.errno(rc)) {
            .SUCCESS => got += @intCast(rc),
            .INTR => {},
            else => @panic("getrandom failed"),
        }
    }
}

test "entropy: fills the whole buffer, and two draws differ" {
    var a: [64]u8 = @splat(0);
    var b: [64]u8 = @splat(0);
    fill(&a);
    fill(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expect(!std.mem.allEqual(u8, &a, 0));
}
