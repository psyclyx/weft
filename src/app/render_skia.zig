//! What the two production renderers share — `render_vulkan.zig` and
//! `render_gl.zig` are each the shared `FrameBuilder` plus a Skia renderer on
//! one GPU API, and differ only in where Skia's frame lands. Everything that
//! is about Skia and the built frame rather than about the target is here, so
//! the two cannot drift in what they draw.

const std = @import("std");
const skia = @import("weft_skia");
const FrameBuilder = @import("frame_builder.zig").FrameBuilder;

/// Register every owned face by its stable font_id (1..5) so shaped glyph ids
/// resolve against the same font bytes.
pub fn registerFaces(renderer: *skia.Skia, fb: *const FrameBuilder) void {
    const face_set = &fb.view.face_set;
    for (face_set.bytes, 1..) |bytes, id| renderer.registerFont(@intCast(id), bytes);
}

/// Draw every built pane, in pane order, onto the frame `renderer` has begun.
pub fn drawPanes(renderer: *skia.Skia, fb: *const FrameBuilder) void {
    for (fb.built_panes.items) |bp| renderer.drawItems(bp.items);
}

/// Account one presented frame in the latency rings.
pub fn recordPresent(fb: *FrameBuilder, frame_start: u64, had_input: bool) void {
    const frame_ns = @import("weft_gfx").stats.nowNs() - frame_start;
    fb.stats.recordFrame(frame_ns);
    if (had_input) fb.stats.recordInput(frame_ns);
    _ = fb.stats.maybeLog(600);
}

/// Debug: WEFT_SKIA_DUMP=<path> writes the first rasterized frame to a PPM so
/// the shape→Skia decode can be eyeballed without a screenshot. One-shot per
/// renderer (`dumped`); best-effort.
pub fn maybeDump(gpa: std.mem.Allocator, dumped: *bool, f: skia.Frame, bgra: bool) void {
    if (dumped.*) return;
    dumped.* = true;
    const path = std.c.getenv("WEFT_SKIA_DUMP") orelse return;
    dumpPpm(gpa, std.mem.sliceTo(path, 0), f, bgra) catch {};
}

/// Write a rasterized Skia frame to a binary P6 PPM.
fn dumpPpm(gpa: std.mem.Allocator, path: []const u8, f: skia.Frame, bgra: bool) !void {
    const header = try std.fmt.allocPrint(gpa, "P6\n{d} {d}\n255\n", .{ f.width, f.height });
    defer gpa.free(header);
    const out = try gpa.alloc(u8, header.len + @as(usize, f.width) * f.height * 3);
    defer gpa.free(out);
    @memcpy(out[0..header.len], header);
    var di = header.len;
    var row: usize = 0;
    while (row < f.height) : (row += 1) {
        const base = row * f.row_bytes;
        var x: usize = 0;
        while (x < f.width) : (x += 1) {
            const p = base + x * 4;
            out[di] = if (bgra) f.pixels[p + 2] else f.pixels[p]; // R
            out[di + 1] = f.pixels[p + 1]; // G
            out[di + 2] = if (bgra) f.pixels[p] else f.pixels[p + 2]; // B
            di += 3;
        }
    }
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = out[0..di] });
}
