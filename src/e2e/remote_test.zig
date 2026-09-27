//! e2e test file — remote places (doc/model.md §3.5, substrate §7): a place
//! carries its real locus, so a peer's and a shell's entries read
//! `locality = remote` by locus and nothing else; a `shell:` place is a
//! filesystem provider the sidebar follows into; a peer's file is an entry
//! that saves back through the peer's write surface when, and only when, the
//! peer granted one.
//!
//! The shell tier runs over a local `sh` (the spawner is pluggable: ssh is
//! the default, not the transport under test); the peer tier over the
//! in-process two-peer harness the projection gates use.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const ide = @import("ide_test.zig");
const projection = @import("projection_test.zig");

const core = h.core;
const Editor = h.Editor;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;
const durable = core.designation.durable;

/// A local `sh` standing in for a remote host's.
const local_sh = [_][]const u8{"/bin/sh"};

fn bootIde(gpa: std.mem.Allocator, proj: *Project, ed: *Editor, loader: *ConfigLoader) !void {
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);
    try h.bootConfigNamed(ed, config_dir, "ide.js", loader);
    try ed.buffers.setDefaultMode(gpa, ed.head.currentMode());
}

fn fact(ed: *Editor, key: []const u8) []const u8 {
    return core.intent.factsFor(ed.ctx).get(key) orelse "";
}

/// What the status line says about where the active entry is.
fn remoteNote(ed: *Editor) !?[]const u8 {
    return h.app.frame_builder.FrameBuilder.remoteNote(t.allocator, ed.ctx.loci, ed.buffers.active().place);
}

test "e2e/remote: a shell place lists, the sidebar follows into it and reveals the file, and its file reads remote by its locus" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    try core.file.writeBytesMakingDirs(gpa, "box/src", "box/src/main.zig", "pub fn main() void {}\n");
    try core.file.writeBytes(gpa, "local.zig", "const x = 1;\n");
    var buf: [4096]u8 = undefined;
    var fbuf: [4096]u8 = undefined;

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    var loader: ConfigLoader = .{ .ed = &ed };
    defer loader.deinit();
    try bootIde(gpa, &proj, &ed, &loader);
    ed.prov.attach_deps.spawner = .{ .command = &local_sh };

    // A local source file: local, and the build is offered.
    ed.runStr("open", "local.zig");
    ed.applyWindow();
    try t.expectEqualStrings("local", fact(&ed, "locality"));
    try t.expect(ide.offered(&ed, "plugin.ide.build"));

    // The shell's directory, by designation: a listing like any other,
    // through the shell's own filesystem provider.
    const dir = try std.fmt.bufPrint(&buf, "weft://shell:box/dir{s}/box", .{proj.root});
    try t.expect(projection.openOk(&ed, dir));
    try t.expectEqualStrings(dir, ed.buffers.active().designationText());
    try t.expectEqualStrings(dir, fact(&ed, "place"));
    {
        const view = ed.toolView() orelse return error.NoListing;
        const listed = try ed.semanticText(view);
        defer gpa.free(listed);
        try t.expect(std.mem.indexOf(u8, listed, "src") != null);
    }

    // A file over the shell: in its directory's place, on the shell's locus.
    // So it reads remote — the build drops for that reason — the sidebar
    // follows onto the shell's directory, and reveals the file there.
    const file = try std.fmt.bufPrint(&fbuf, "weft://shell:box/file{s}/box/src/main.zig", .{proj.root});
    try t.expect(projection.openOk(&ed, file));
    try t.expectEqualStrings(file, ed.buffers.active().designationText());
    {
        const text = try ed.textAlloc();
        defer gpa.free(text);
        try t.expectEqualStrings("pub fn main() void {}\n", text);
    }
    try t.expectEqualStrings("remote", fact(&ed, "locality"));
    try t.expect(!ide.offered(&ed, "plugin.ide.build"));
    try t.expect(ide.offered(&ed, "plugin.ide.format")); // source is still source
    var pbuf: [4096]u8 = undefined;
    const parent = try std.fmt.bufPrint(&pbuf, "weft://shell:box/dir{s}/box/src", .{proj.root});
    try t.expectEqualStrings(parent, fact(&ed, "place"));
    ed.applyWindow();
    try t.expectEqualStrings(parent, try projection.sidebarShows(&ed));
    try t.expectEqualStrings(file, projection.sidebarHighlights(&ed) orelse return error.NothingRevealed);

    // The status line says where it is and how reachable (R5): the channel
    // has answered, so connected.
    {
        const note = (try remoteNote(&ed)) orelse return error.NoRemoteNote;
        defer gpa.free(note);
        try t.expectEqualStrings("shell:box connected", note);
    }
    // A process cannot start there: the place has no directory of ours.
    try t.expect(core.place.realize(ed.buffers.active().place, ed.ctx.realizer) == .elsewhere);

    // Back to the local file: local again, the build offered again.
    ed.runStr("open", "local.zig");
    ed.applyWindow();
    try t.expectEqualStrings("local", fact(&ed, "locality"));
    try t.expect(ide.offered(&ed, "plugin.ide.build"));
}

test "e2e/remote: a shell that is gone reads offline in the status line, and its directory refuses by name" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    try core.file.writeBytesMakingDirs(gpa, "box", "box/a.txt", "a\n");
    var buf: [4096]u8 = undefined;

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    // A spawner whose far side leaves at once: the shell dies under us.
    const dead = [_][]const u8{ "/bin/sh", "-c", "exit 0" };
    ed.prov.attach_deps.spawner = .{ .command = &dead };

    const dir = try std.fmt.bufPrint(&buf, "weft://shell:gone/dir{s}/box", .{proj.root});
    const outcome = try core.command.run(ed.commands, ed.ctx, "open", &.{.{ .string = dir }});
    try t.expect(outcome == .string);
    try t.expectEqualStrings("open: the shell is not answering", outcome.string);
    const l = ed.ctx.loci.?.resolve(.{ .shell = "gone" }) orelse return error.NoLocus;
    try t.expectEqual(core.locus.Liveness.offline, ed.ctx.loci.?.liveness(l));
}
