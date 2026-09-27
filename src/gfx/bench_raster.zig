//! Raster timing instrument — the missing half of the perf gates.
//!
//! `latency_test.zig` measures keystroke→dispatch and says in its own header
//! that it excludes rasterization. `popup_layout_test.zig` asserts geometry and
//! deliberately refuses to assert pixels. So until this file, a rasterizer
//! change could make every frame three times slower with the whole suite green.
//!
//! What it does: build a real `View` over a real source file at a realistic
//! window size, then time `Skia.drawItems` and `end` separately over many
//! iterations. The framebuffer is hashed so an optimization that changes output
//! is caught rather than celebrated — a faster wrong picture is not a win.
//!
//! Run: `zig build bench-raster`. The workload deliberately uses a repo file
//! rather than a screen of solid text: real code is mostly short lines and
//! whitespace, and a full 1080p block of glyphs overstates the draw cost by
//! roughly the ratio of its fill to a real document's.

const std = @import("std");
const font_provider = @import("weft_font_provider");
const scene = @import("weft_scene");
const core = @import("weft_core");
const view_mod = @import("view.zig");
const region = @import("region.zig");
const skia_mod = @import("weft_skia");
const nowNs = core.task.nowNs;

const Case = struct {
    name: []const u8,
    path: []const u8,
    w: u32,
    h: u32,
};

/// Two shapes of the same question: a typical editor window over ordinary
/// source, and a maximized one. Both over a real file.
const cases = [_]Case{
    .{ .name = "window-1600x1000", .path = "src/core/Document.zig", .w = 1600, .h = 1000 },
    .{ .name = "maximized-1920x1080", .path = "src/core/Document.zig", .w = 1920, .h = 1080 },
};

fn fnv1a(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

fn median(xs: []u64) u64 {
    std.mem.sort(u64, xs, {}, std.sort.asc(u64));
    return xs[xs.len / 2];
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const iters: usize = 40;
    std.debug.print("raster bench — {d} iterations, median, CPU raster path\n\n", .{iters});

    for (cases) |case| {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        const text = std.Io.Dir.cwd().readFileAlloc(threaded.io(), case.path, gpa, .unlimited) catch |err| {
            std.debug.print("{s}: SKIP ({s}: {s})\n", .{ case.name, case.path, @errorName(err) });
            continue;
        };
        defer gpa.free(text);

        const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
        defer pool.deinit();
        var view = try view_mod.View.init(gpa, font_provider.defaultMono(), 16);
        defer view.deinit();
        var ed = try core.Editor.init(gpa, pool, "bench");
        defer ed.deinit(gpa);
        try ed.insertText(gpa, text);

        // Build the frame once; the scene is what we are timing the drawing of,
        // not the building of (that is `View.build`, timed separately below).
        const projection = scene.Mat4.ortho(0, @floatFromInt(case.w), @floatFromInt(case.h), 0, -1, 1);
        const w2p = scene.mvpToScenePixel(projection, @floatFromInt(case.w), @floatFromInt(case.h)).?;
        const frame_rect: region.Rect = .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(case.w),
            .h = @floatFromInt(case.h),
        };

        var snap_ns = try gpa.alloc(u64, iters);
        defer gpa.free(snap_ns);
        var build_ns = try gpa.alloc(u64, iters);
        defer gpa.free(build_ns);
        var draw_ns = try gpa.alloc(u64, iters);
        defer gpa.free(draw_ns);
        var end_ns = try gpa.alloc(u64, iters);
        defer gpa.free(end_ns);

        var renderer = try skia_mod.Skia.init(null, false, false);
        defer renderer.deinit();
        for (view.face_set.bytes, 1..) |bytes, id| renderer.registerFont(@intCast(id), bytes);

        var items: usize = 0;
        var glyphs: usize = 0;
        var hash: u64 = 0;

        for (0..iters) |i| {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            view.resetFrame();
            var top_row: usize = 0;

            // The frame's input — what `View.build` reads — is taken first.
            var t0 = nowNs();
            var snap = try core.TextSnapshot.of(&ed, arena.allocator());
            snap_ns[i] = nowNs() - t0;
            defer snap.release(gpa);

            t0 = nowNs();
            var built = try view.build(arena.allocator(), &snap, .{ .mode = "normal" }, &top_row, frame_rect, .{}, w2p);
            build_ns[i] = nowNs() - t0;
            defer built.deinit(gpa);

            items = built.items.len;
            glyphs = 0;
            for (built.items) |it| switch (it) {
                .glyph => glyphs += 1,
                .rect => {},
                .path => {},
            };

            try renderer.begin(case.w, case.h, view.theme.background);
            t0 = nowNs();
            renderer.drawItems(built.items);
            draw_ns[i] = nowNs() - t0;

            t0 = nowNs();
            const out = try renderer.end(case.w, case.h);
            end_ns[i] = nowNs() - t0;

            // Hash the whole framebuffer: the correctness oracle for any
            // change that claims to be output-identical.
            const bytes = out.pixels[0 .. out.row_bytes * case.h];
            const h = fnv1a(bytes);
            if (i > 0 and h != hash) {
                std.debug.print("{s}: NONDETERMINISTIC framebuffer\n", .{case.name});
            }
            hash = h;
        }

        const s = median(snap_ns);
        const b = median(build_ns);
        const d = median(draw_ns);
        const e = median(end_ns);
        std.debug.print(
            \\{s}  ({d} items, {d} glyphs)
            \\  snapshot     {d:.4} ms
            \\  View.build   {d:.3} ms
            \\  drawItems    {d:.3} ms
            \\  end          {d:.3} ms
            \\  raster total {d:.3} ms
            \\  fb hash      0x{x}
            \\
            \\
        , .{
            case.name,
            items,
            glyphs,
            @as(f64, @floatFromInt(s)) / 1e6,
            @as(f64, @floatFromInt(b)) / 1e6,
            @as(f64, @floatFromInt(d)) / 1e6,
            @as(f64, @floatFromInt(e)) / 1e6,
            @as(f64, @floatFromInt(d + e)) / 1e6,
            hash,
        });
    }
}
