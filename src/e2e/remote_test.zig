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

/// Fold a requested save once its worker is done: whether it saved. Bounded
/// by a generous deadline, a genuine-hang backstop (`Editor.waitSave`'s).
fn awaitSave(te: *core.Editor) bool {
    const deadline = core.task.nowNs() + 30 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        if (te.pollSave(t.allocator)) return true;
        if (te.save_state != .saving) return false;
        std.Thread.yield() catch {};
    }
    return false;
}

/// Fold a requested backing poll once its worker is done: whether the
/// buffer changed. False at once when none is in flight.
fn awaitPoll(te: *core.Editor) !bool {
    const deadline = core.task.nowNs() + 30 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        if (te.poll_state != .polling) return false;
        const changed = try te.pollBacking(t.allocator);
        if (te.poll_state != .polling) return changed;
        std.Thread.yield() catch {};
    }
    return false;
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

test "e2e/remote: a far-side path is never a local one — recents keep the shell file's designation, and opening the same path here opens the local file" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    try core.file.writeBytesMakingDirs(gpa, "box/etc", "box/etc/hosts", "far side\n");
    var fbuf: [4096]u8 = undefined;
    var lbuf: [4096]u8 = undefined;

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    var loader: ConfigLoader = .{ .ed = &ed };
    defer loader.deinit();
    try bootIde(gpa, &proj, &ed, &loader);
    ed.prov.attach_deps.spawner = .{ .command = &local_sh };

    // The "far side" is this machine's sh, so the far-side path also names
    // a local file — exactly what a remote path must never be taken for.
    const file = try std.fmt.bufPrint(&fbuf, "weft://shell:box/file{s}/box/etc/hosts", .{proj.root});
    const local = try std.fmt.bufPrint(&lbuf, "{s}/box/etc/hosts", .{proj.root});
    try t.expect(projection.openOk(&ed, file));
    const shell_id = ed.buffers.active().id;
    _ = try core.command.run(ed.commands, ed.ctx, "project.remember", &.{});
    const recent = try core.command.run(ed.commands, ed.ctx, "project.recent", &.{});
    var lines = std.mem.splitScalar(u8, recent.string, '\n');
    try t.expectEqualStrings(file, lines.first());

    // Opening the path here is the local file: a new entry, not the shell's.
    ed.runStr("file.open", local);
    try t.expect(ed.buffers.active().id != shell_id);
    var hbuf: [4096]u8 = undefined;
    const here = try std.fmt.bufPrint(&hbuf, "weft://here/file{s}", .{local});
    try t.expectEqualStrings(here, ed.buffers.active().designationText());
}

test "e2e/remote: a recent that no longer opens leaves Open Recent instead of being offered again" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    try core.file.writeBytes(gpa, "here.zig", "const x = 1;\n");
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    var loader: ConfigLoader = .{ .ed = &ed };
    defer loader.deinit();
    try bootIde(gpa, &proj, &ed, &loader);
    // A host that is gone: its shell exits as soon as it starts.
    const dead = [_][]const u8{ "/bin/sh", "-c", "exit 0" };
    ed.prov.attach_deps.spawner = .{ .command = &dead };
    ed.runStr("file.open", "here.zig");
    var lbuf: [4096]u8 = undefined;
    const here = try std.fmt.bufPrint(&lbuf, "{s}/here.zig", .{proj.root});
    const gone = "weft://shell:gone/file/etc/hosts";
    const list = try std.fmt.allocPrint(gpa, "{s}\n{s}", .{ gone, here });
    defer gpa.free(list);
    try ed.plugin_kv.put(gpa, "project", "recent", list);

    ed.run("project.open-recent");
    try t.expect(ed.pick.active);
    ed.press("Return", ""); // the first: the file on the host that is gone
    try t.expect(!ed.pick.active);
    const recent = try core.command.run(ed.commands, ed.ctx, "project.recent", &.{});
    try t.expectEqualStrings(here, recent.string);
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

    // An edit saves back through the peer's write surface — on a pool
    // worker, so each step is waited for.
    const te = b.buffers.active().textEditor().?;
    te.moveTo(te.text().byteLen());
    try te.insertText(gpa, "// edited\n");
    try te.requestSave(gpa);
    try t.expect(awaitSave(te));
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
    // Another step (what a dispatch would cut: this drives the editor
    // directly, and a caret move is no undo boundary of its own).
    te.history.barrier();
    try te.insertText(gpa, "// mine\n");
    try te.requestSave(gpa);
    try t.expect(!awaitSave(te));
    try t.expect(te.save_state == .stale);
    {
        const on_disk = try pair.disk(gpa);
        defer gpa.free(on_disk);
        try t.expectEqualStrings("pub fn main() void {}\n// edited\n// theirs\n", on_disk);
    }
    // (A poll the frame loop asked for before the peer's write is folded
    // first: it saw nothing new, and says so.)
    _ = try awaitPoll(te);
    try te.requestBackingPoll(gpa);
    try t.expect(try awaitPoll(te));
    try t.expect(te.save_state == .idle);
    const merged = "// mine\npub fn main() void {}\n// edited\n// theirs\n";
    {
        const text = try b.textAlloc();
        defer gpa.free(text);
        try t.expectEqualStrings(merged, text);
    }
    try te.requestSave(gpa);
    try t.expect(awaitSave(te));
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

test "e2e/remote: a peer file's save and poll never run on the frame — a slow peer stalls a worker, not a frame" {
    const gpa = t.allocator;
    var pair: PeerPair = undefined;
    try pair.init(gpa, .read_write);
    defer pair.deinit(gpa);
    const b = &pair.b;
    try t.expect(projection.openOk(b, try pair.fileDesignation()));
    const te = b.buffers.active().textEditor().?;
    const exchange = &pair.tree.exchange;
    exchange.on_frame.store(0, .monotonic);

    // The peer is slow: it answers only when the gate opens. The frame that
    // asked for the save is back at once, the save still in flight.
    var gate: core.task.Gate = .{};
    exchange.hold = &gate;
    try te.insertText(gpa, "// edited\n");
    const asked = core.task.nowNs();
    try te.requestSave(gpa);
    const frame_ns = core.task.nowNs() - asked;
    std.debug.print("[e2e/remote] requestSave with the peer not answering: {d} us on the frame\n", .{frame_ns / std.time.ns_per_us});
    try t.expect(te.save_state == .saving);
    try t.expectEqual(@as(usize, 0), exchange.on_frame.load(.monotonic));
    gate.open();
    try t.expect(awaitSave(te));
    exchange.hold = null;

    // The poll, likewise: off the frame, and it sees the peer's own write.
    // (A poll the open asked for is folded first: it saw nothing new.)
    _ = try awaitPoll(te);
    try core.file.writeBytes(gpa, "shared/src/main.zig", "// theirs\n");
    try te.requestBackingPoll(gpa);
    try t.expect(try awaitPoll(te));
    try t.expectEqual(@as(usize, 0), exchange.on_frame.load(.monotonic));
    try t.expect(exchange.off_frame.load(.monotonic) > 0);
}

test "e2e/remote: a peer save keeps the file's mode, and a temp a lost save left behind neither blocks the next save nor outlives it" {
    const gpa = t.allocator;
    var pair: PeerPair = undefined;
    try pair.init(gpa, .read_write);
    defer pair.deinit(gpa);
    const b = &pair.b;
    // An executable, and the litter of a save whose connection dropped
    // between the upload and the move (the old fixed name, and a new one).
    try t.expectEqual(@as(c_int, 0), std.c.chmod("shared/src/main.zig", 0o755));
    try core.file.writeBytes(gpa, "shared/src/.main.zig.weft-tmp", "half a save");
    try core.file.writeBytes(gpa, "shared/src/.main.zig.weft-tmp-0123456789abcdef", "half a save");

    try t.expect(projection.openOk(b, try pair.fileDesignation()));
    const te = b.buffers.active().textEditor().?;
    te.moveTo(te.text().byteLen());
    try te.insertText(gpa, "// edited\n");
    try te.requestSave(gpa);
    try t.expect(awaitSave(te));
    try t.expectEqual(@as(u32, 0o755), core.file.statFull(gpa, "shared/src/main.zig").mode);
    try t.expect(core.file.statFull(gpa, "shared/src/.main.zig.weft-tmp").kind == core.file.Stat.absent.kind);
    try t.expect(core.file.statFull(gpa, "shared/src/.main.zig.weft-tmp-0123456789abcdef").kind == core.file.Stat.absent.kind);
    const on_disk = try pair.disk(gpa);
    defer gpa.free(on_disk);
    try t.expectEqualStrings("pub fn main() void {}\n// edited\n", on_disk);
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
    try b.head.echo.say(gpa, "");
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
