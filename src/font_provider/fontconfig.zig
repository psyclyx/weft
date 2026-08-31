//! Fontconfig implementation of the platform font-file provider.

const std = @import("std");
const contract = @import("contract");
const Request = contract.Request;

const c = @cImport({
    @cInclude("fontconfig/fontconfig.h");
});

pub fn loadFace(allocator: std.mem.Allocator, request: Request) !?contract.LoadedFace {
    _ = c.FcInit();
    const pattern = c.FcPatternCreate() orelse return null;
    defer c.FcPatternDestroy(pattern);
    _ = c.FcPatternAddString(pattern, c.FC_FAMILY, @ptrCast(request.family.ptr));
    _ = c.FcPatternAddInteger(pattern, c.FC_WEIGHT, if (request.bold) c.FC_WEIGHT_BOLD else c.FC_WEIGHT_REGULAR);
    _ = c.FcPatternAddInteger(pattern, c.FC_SLANT, if (request.italic) c.FC_SLANT_ITALIC else c.FC_SLANT_ROMAN);
    _ = c.FcConfigSubstitute(null, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);

    var result: c.FcResult = undefined;
    const match = c.FcFontMatch(null, pattern, &result) orelse return null;
    defer c.FcPatternDestroy(match);

    var file: [*c]c.FcChar8 = undefined;
    if (c.FcPatternGetString(match, c.FC_FILE, 0, &file) != c.FcResultMatch) return null;
    var face_index: c_int = 0;
    if (c.FcPatternGetInteger(match, c.FC_INDEX, 0, &face_index) != c.FcResultMatch or face_index < 0)
        face_index = 0;
    const path = std.mem.span(@as([*:0]const u8, @ptrCast(file)));
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    return .{
        .bytes = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .unlimited),
        .face_index = @intCast(face_index),
    };
}
