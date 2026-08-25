//! Conservative provider for targets without a native family resolver yet.

const std = @import("std");
const contract = @import("contract");
const Request = contract.Request;

pub fn loadFace(_: std.mem.Allocator, _: Request) !?contract.LoadedFace {
    return null;
}
