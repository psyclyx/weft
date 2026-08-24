//! Host-only dired session facade.
//!
//! A dired session binds the portable model to filesystem, target, view, and
//! field registries. Keep that adapter behind this separate named module so a
//! consumer of `weft_dired` cannot reach host services through the portable
//! facade or a relative import.

const std = @import("std");

pub const session = @import("weft_dired_session");
pub const Plugin = session.Plugin;
pub const Session = session.Session;

test {
    std.testing.refAllDecls(@This());
}
