//! Platform-selected font-file provider facade.
//!
//! Text shaping consumes bytes and does not know how a platform resolves a
//! family name. The build supplies one implementation module here — fontconfig
//! on Linux, CoreText on macOS — and a family neither resolves leaves the
//! caller on its embedded mono fallback, without `weft_text`, `View`, or
//! `FaceSet` knowing which platform answered.

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
