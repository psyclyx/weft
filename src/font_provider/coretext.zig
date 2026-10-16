//! CoreText implementation of the platform font-file provider (macOS): the
//! family's file and PostScript name from CoreText (`coretext.c`), its bytes
//! from disk, and — for the collections macOS keeps many families in — the
//! face's index in the file from its PostScript name (`ttc.zig`).

comptime {
    if (@import("builtin").os.tag != .macos) @compileError("font_provider/coretext.zig is macOS-only");
}

const std = @import("std");
const contract = @import("contract");
const ttc = @import("ttc");
const Request = contract.Request;

const c = @cImport(@cInclude("coretext.h"));

pub fn loadFace(allocator: std.mem.Allocator, request: Request) !?contract.LoadedFace {
    var path: [std.fs.max_path_bytes:0]u8 = undefined;
    var postscript: [256:0]u8 = undefined;
    if (c.weft_coretext_match(request.family.ptr, @intFromBool(request.bold), @intFromBool(request.italic), &path, path.len, &postscript, postscript.len) != 0)
        return null;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), std.mem.sliceTo(&path, 0), allocator, .unlimited);
    errdefer allocator.free(bytes);
    const index = ttc.faceIndex(bytes, std.mem.sliceTo(&postscript, 0)) orelse {
        allocator.free(bytes);
        return null;
    };
    return .{ .bytes = bytes, .face_index = index };
}
