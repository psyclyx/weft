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
    ed.runStr("file.open", "local.zig");
    ed.applyWindow();
    try t.expectEqualStrings("local", fact(&ed, "locality"));
    try t.expect(ide.offered(&ed, "plugin.code.run"));

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
    try t.expect(!ide.offered(&ed, "plugin.code.run"));
    try t.expect(ide.offered(&ed, "plugin.code.format")); // source is still source
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
    ed.runStr("file.open", "local.zig");
    ed.applyWindow();
    try t.expectEqualStrings("local", fact(&ed, "locality"));
    try t.expect(ide.offered(&ed, "plugin.code.run"));
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
    const outcome = try core.command.run(ed.commands, ed.ctx, "file.open", &.{.{ .string = dir }});
    try t.expect(outcome == .string);
    try t.expectEqualStrings("open: the shell is not answering", outcome.string);
    const l = ed.ctx.loci.?.resolve(.{ .shell = "gone" }) orelse return error.NoLocus;
    try t.expectEqual(core.locus.Liveness.offline, ed.ctx.loci.?.liveness(l));
}

/// Bob, connected to alice, who shares `<project>/shared` granting `access`.
const PeerPair = struct {
    proj: Project,
    a: Editor,
    b: Editor,
    loader: ConfigLoader,
    link: h.Loopback,
    fp: [24]u8,
    tree: projection.PeerTree,
    file_name: [128]u8,

    fn init(self: *PeerPair, gpa: std.mem.Allocator, access: h.fs_remote.Access) !void {
        try self.proj.init(gpa);
        errdefer self.proj.deinit();
        try core.file.writeBytesMakingDirs(gpa, "shared/src", "shared/src/main.zig", "pub fn main() void {}\n");
        try Editor.initNamed(gpa, &self.a, "alice");
        try Editor.initNamed(gpa, &self.b, "bob");
        self.loader = .{ .ed = &self.b };
        try bootIde(gpa, &self.proj, &self.b, &self.loader);
        try self.b.enableCollabCommands();
        try h.Loopback.init(&self.link, gpa, &self.a, &self.b, "alice", "bob");
        self.fp = self.link.peer_sess.peerFingerprint() orelse return error.NoHandshake;
        const shared_root = try std.fmt.allocPrint(gpa, "{s}/shared", .{self.proj.root});
        defer gpa.free(shared_root);
        try self.tree.initGranting(gpa, &self.b, shared_root, &self.fp, access);
    }

    fn deinit(self: *PeerPair, gpa: std.mem.Allocator) void {
        self.tree.deinit(gpa, &self.b);
        self.link.deinit();
        self.loader.deinit();
        self.b.deinit();
        self.a.deinit();
        self.proj.deinit();
    }

    /// `weft://<alice>/file/src/main.zig`.
    fn fileDesignation(self: *PeerPair) ![]const u8 {
        return (durable.Designation{ .authority = .{ .peer = &self.fp }, .kind = .file, .ref = "/src/main.zig" }).render(&self.file_name);
    }

    fn disk(self: *PeerPair, gpa: std.mem.Allocator) ![]u8 {
        _ = self;
        return core.file.readAlloc(gpa, "shared/src/main.zig");
    }
};

test "e2e/remote: a peer's file is editable where the peer granted a write surface — guarded save, external changes merged as the backing peer's" {
    const gpa = t.allocator;
    var pair: PeerPair = undefined;
    try pair.init(gpa, .read_write);
    defer pair.deinit(gpa);
    const b = &pair.b;

    const designation = try pair.fileDesignation();
    try t.expect(projection.openOk(b, designation));
    try t.expectEqualStrings(designation, b.buffers.active().designationText());
    try t.expect(b.buffers.active().read_only == null);
    // In the peer's place, on the peer's locus: remote — so the build drops
    // for its locality, now that the file is editable source.
    try t.expectEqualStrings(pair.tree.root_designation, fact(b, "place"));
    try t.expectEqualStrings("remote", fact(b, "locality"));
    try t.expectEqualStrings("text", fact(b, "posture"));
    try t.expect(!ide.offered(b, "plugin.code.run"));
    try t.expect(ide.offered(b, "plugin.code.format"));

    // R2 + R5: the locus is the fingerprint; whatever connection reaches it
    // is a binding, and the status line reads its liveness.
    const loci = b.ctx.loci.?;
    const locus = loci.resolve(.{ .peer = &pair.fp }) orelse return error.NoPeerLocus;
    try t.expectEqual(locus, b.buffers.active().place.locus());
    var conn = try core.session.Conn.init(gpa, pair.link.peer_sess, "alice", .client);
    defer conn.deinit();
    loci.bindPeer(locus, &conn);
    {
        const note = (try remoteNote(b)) orelse return error.NoRemoteNote;
        defer gpa.free(note);
        try t.expect(std.mem.endsWith(u8, note, " connected"));
    }
    loci.bindPeer(locus, null);
    {
        const note = (try remoteNote(b)) orelse return error.NoRemoteNote;
        defer gpa.free(note);
        try t.expect(std.mem.endsWith(u8, note, " offline"));
    }

    // An edit saves back through the peer's write surface. The peer's tree
    // rides the connection the frame thread ticks, so every step lands on
    // the call: no worker to wait for.
    const te = b.buffers.active().textEditor().?;
    te.moveTo(te.text().byteLen());
    try te.insertText(gpa, "// edited\n");
    try te.requestSave(gpa);
    try t.expect(te.pollSave(gpa));
    try t.expect(!try te.isDirty(gpa));
    {
        const on_disk = try pair.disk(gpa);
        defer gpa.free(on_disk);
        try t.expectEqualStrings("pub fn main() void {}\n// edited\n", on_disk);
    }

    // The peer's disk moves while this side has unsaved work: the save is
    // STALE and writes nothing; the poll merges the peer's change as the
    // backing peer's ops beside the unsaved edit; the retry lands both.
    try core.file.writeBytes(gpa, "shared/src/main.zig", "pub fn main() void {}\n// edited\n// theirs\n");
    te.moveTo(0);
    try te.insertText(gpa, "// mine\n");
    try te.requestSave(gpa);
    try t.expect(!te.pollSave(gpa));
    try t.expect(te.save_state == .stale);
    {
        const on_disk = try pair.disk(gpa);
        defer gpa.free(on_disk);
        try t.expectEqualStrings("pub fn main() void {}\n// edited\n// theirs\n", on_disk);
    }
    // (A poll the frame loop asked for before the peer's write is folded
    // first: it saw nothing new, and says so.)
    _ = try te.pollBacking(gpa);
    try te.requestBackingPoll(gpa);
    try t.expect(try te.pollBacking(gpa));
    try t.expect(te.save_state == .idle);
    const merged = "// mine\npub fn main() void {}\n// edited\n// theirs\n";
    {
        const text = try b.textAlloc();
        defer gpa.free(text);
        try t.expectEqualStrings(merged, text);
    }
    try te.requestSave(gpa);
    try t.expect(te.pollSave(gpa));
    {
        const on_disk = try pair.disk(gpa);
        defer gpa.free(on_disk);
        try t.expectEqualStrings(merged, on_disk);
    }
    // No temp left beside it.
    try t.expect(core.file.statFull(gpa, "shared/src/.main.zig.weft-tmp").kind == core.file.Stat.absent.kind);

    // The peer's own edit is not ours to undo: undo takes back only "// mine".
    b.run("edit.undo");
    {
        const text = try b.textAlloc();
        defer gpa.free(text);
        try t.expectEqualStrings("pub fn main() void {}\n// edited\n// theirs\n", text);
    }
}

test "e2e/remote: a peer's file without a write grant is read-only and says why" {
    const gpa = t.allocator;
    var pair: PeerPair = undefined;
    try pair.init(gpa, .read);
    defer pair.deinit(gpa);
    const b = &pair.b;

    try t.expect(projection.openOk(b, try pair.fileDesignation()));
    try t.expectEqualStrings(h.app.peer_file.refuse_no_write, b.buffers.active().read_only orelse return error.NotReadOnly);
    try t.expectEqualStrings("remote", fact(b, "locality"));
    // Said when it opens…
    try t.expect(std.mem.indexOf(u8, b.echoText(), "without a write grant") != null);
    b.head.echo.clearRetainingCapacity();
    // …and by every edit it refuses: the entry rests structural, so a key
    // types nothing, and an edit that reaches the door is refused with the
    // entry's own reason.
    try t.expectEqualStrings("structural", fact(b, "posture"));
    b.typeText("x");
    try t.expectError(error.Unauthorized, b.ctx.edit(.{ .start = 0, .end = 0 }, "x"));
    try t.expect(std.mem.indexOf(u8, b.echoText(), "without a write grant") != null);
    const text = try b.textAlloc();
    defer gpa.free(text);
    try t.expectEqualStrings("pub fn main() void {}\n", text);
}
