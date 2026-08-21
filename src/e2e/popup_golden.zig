//! popup-layout golden machinery: the committed-artifact shape and its
//! (de)serialization, plus a structural equality check. Deliberately knows
//! nothing about the editor, `Pick`, or how a scenario is driven —
//! `popup_layout_test.zig` is the policy (which scenarios, how they're
//! built, what counts as a mismatch); this is the reusable middle, the same
//! split `latency.zig`/`latency_test.zig` uses for the dispatch-latency
//! instrument.
//!
//! WHY layout-level goldens, not pixels (the design choice rendering P2's
//! guard makes deliberately — see doc/rendering.md and the popup-layout
//! test file's own doc comment): `popup.CaretLayout` is pure arithmetic over
//! fixed metrics (cell width, line height, ascent — all derived once from
//! the embedded font at a fixed `em`), so it reproduces bit-for-bit run to
//! run. A `.ppm` pixel dump depends on the rasterizer's AA/hinting, which
//! this codebase's own experience (doc/rendering.md) already found too
//! brittle to assert on directly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const weft = @import("weft");
const popup = weft.view.popup;

/// One named scenario's expected layout, plus an optional coarse pixel
/// smoke hash (belt-and-braces on top of the layout-level assertion — see
/// `popup_layout_test.zig`'s "pixel_smoke" case). `0` = not checked.
pub const Golden = struct {
    name: []const u8,
    layout: popup.CaretLayout,
    pixel_hash: u64 = 0,
};

pub const GoldenFile = struct {
    note: []const u8 = "",
    cases: []const Golden,
};

/// Load the committed goldens from `path` (repo-relative). Caller must
/// `std.zon.parse.free(gpa, result)`.
pub fn loadGoldens(gpa: Allocator, path: []const u8) !GoldenFile {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const src = try std.Io.Dir.cwd().readFileAllocOptions(threaded.io(), path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    return std.zon.parse.fromSliceAlloc(GoldenFile, gpa, src, null, .{});
}

/// Serialize `file` as ZON and write it to `path` (repo-relative),
/// replacing whatever is there.
pub fn saveGoldens(gpa: Allocator, path: []const u8, file: GoldenFile) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.zon.stringify.serialize(file, .{}, &aw.writer);
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{
        .sub_path = path,
        .data = aw.writer.buffer[0..aw.writer.end],
    });
}

/// Find `name`'s entry, or null if the scenario is new (no prior recording).
pub fn find(file: GoldenFile, name: []const u8) ?Golden {
    for (file.cases) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

/// Render `layout` as ZON text (caller frees) — used both to WRITE a fresh
/// golden and to COMPARE one: `CaretLayout` nests slices/enums/optionals
/// deep enough that a hand-rolled structural comparator would just be a
/// second, driftable copy of this shape; instead, two layouts are "equal"
/// exactly when their canonical ZON texts are byte-identical, and a
/// mismatch's own printed texts ARE the diff.
pub fn layoutText(gpa: Allocator, layout: popup.CaretLayout) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.zon.stringify.serialize(layout, .{}, &aw.writer);
    return aw.toOwnedSlice();
}
