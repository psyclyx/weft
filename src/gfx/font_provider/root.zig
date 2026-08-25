//! Platform-selected font-file provider facade.
//!
//! Text shaping consumes bytes and does not know how a platform resolves a
//! family name. The build supplies one implementation module here; Linux uses
//! fontconfig, while unsupported targets return no optional face and let the
//! caller use its embedded mono fallback. A CoreText implementation can replace
//! the provider on Darwin without changing `weft_text`, `View`, or `FaceSet`.

const std = @import("std");
const contract = @import("contract");
const implementation = @import("implementation");

pub const Request = contract.Request;
pub const LoadedFace = contract.LoadedFace;

/// Build-selected, portable font bytes used for code and as the reliable
/// fallback when the platform cannot resolve an optional proportional face.
pub fn defaultMono() []const u8 {
    return @embedFile("font_mono");
}

pub fn loadFace(allocator: std.mem.Allocator, request: Request) !?LoadedFace {
    return implementation.loadFace(allocator, request);
}

comptime {
    if (!@hasDecl(implementation, "loadFace"))
        @compileError("font provider implementation must export loadFace");
}
