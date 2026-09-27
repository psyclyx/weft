//! e2e test file — designations (doc/model.md §2.1–2.2): every entry names
//! what it opens; `open` takes that name and routes it by kind; and what
//! outlives an entry (a jump, a viewport) holds the name, never the slot.
//!
//! Driven through the shipped config.js, the way a person gets there: `open`
//! run by name (the harness resolves a relative name against the project, as
//! the command line would), the plugins' own commands, `buffer-close`.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const Editor = h.Editor;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;
const durable = core.designation.durable;

/// A weft booted from config.js in a throwaway project holding
///
///   a.txt, sub/inner.txt
///
/// showing the dashboard, as a no-file launch does.
const App = struct {
    proj: Project = undefined,
    ed: Editor = undefined,
    loader: ConfigLoader = undefined,

    fn init(self: *App, gpa: std.mem.Allocator) !void {
        try self.proj.init(gpa);
        errdefer self.proj.deinit();
        try Editor.init(gpa, &self.ed);
        errdefer self.ed.deinit();
        self.loader = .{ .ed = &self.ed };
        errdefer self.loader.deinit();
        try core.file.writeBytes(gpa, "a.txt", "alpha\nbeta\n");
        try core.file.writeBytesMakingDirs(gpa, "sub", "sub/inner.txt", "INNER\n");
        const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{self.proj.prev_cwd});
        defer gpa.free(config_dir);
        try h.bootConfigNamed(&self.ed, config_dir, "config.js", &self.loader);
        try self.ed.buffers.setDefaultMode(gpa, self.ed.head.currentMode());
        self.ed.run("dashboard");
        self.ed.applyWindow();
    }

    fn deinit(self: *App) void {
        self.loader.deinit();
        self.ed.deinit();
        self.proj.deinit();
    }

    /// `weft://here/<kind><root><rest>` for this project.
    fn under(self: *App, buf: []u8, kind: []const u8, rest: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "weft://here/{s}{s}{s}", .{ kind, self.proj.root, rest }) catch unreachable;
    }
};

fn named(ed: *Editor) []const u8 {
    return ed.buffers.active().designationText();
}

/// Run `open` exactly as a guest's `weft.openDesignation` does — no harness
/// help with relative names — and answer what it said, if it refused.
fn openRaw(ed: *Editor, spec: []const u8) ?[]const u8 {
    const outcome = core.command.run(ed.commands, ed.ctx, "open", &.{.{ .string = spec }}) catch return "error";
    ed.applyWindow();
    return switch (outcome) {
        .string => |why| why,
        else => null,
    };
}

test "e2e/designation: every kind of entry names what it opens" {
    var app: App = undefined;
    try app.init(t.allocator);
    defer app.deinit();
    const ed = &app.ed;
    var buf: [4096]u8 = undefined;

    // A projection: the dashboard, re-run by name.
    try t.expectEqualStrings("weft://here/dashboard/main", named(ed));

    // A file, by its absolute path.
    ed.runStr("open", "a.txt");
    try t.expectEqualStrings(app.under(&buf, "file", "/a.txt"), named(ed));

    // A document with no file: its minted id.
    ed.runStr("buffer-create", "*notes*");
    const doc = durable.parse(named(ed)) orelse return error.NotADesignation;
    try t.expect(doc.kind == .doc);
    try t.expect(doc.docId().?.eql(ed.buffers.active().textEditor().?.doc.id));

    // A directory's listing is that directory — named, and titled, absolute.
    ed.runStr("open", "sub");
    try t.expectEqualStrings(app.under(&buf, "dir", "/sub"), named(ed));
    try t.expect(std.mem.startsWith(u8, ed.bufferName(), "files: /") or std.mem.startsWith(u8, ed.bufferName(), "files: ~"));
    try t.expect(std.mem.endsWith(u8, ed.bufferName(), "/sub"));

    // A live process.
    ed.runStr("repl-start", "cat");
    try t.expectEqualStrings("weft://here/proc/repl", named(ed));

    // The facts say the same: the `entry` builtin is the designation.
    try t.expectEqualStrings("weft://here/proc/repl", core.intent.factsFor(ed.ctx).get("entry").?);
    ed.run("repl-quit");
}

test "e2e/designation: open routes by kind — a file at a position, a closed document, a re-run projection, a live and a gone process" {
    var app: App = undefined;
    try app.init(t.allocator);
    defer app.deinit();
    const ed = &app.ed;
    const gpa = t.allocator;
    var buf: [4096]u8 = undefined;

    // A file, at the position its locator names.
    const at_beta = try std.fmt.allocPrint(gpa, "{s}?at=6", .{app.under(&buf, "file", "/a.txt")});
    defer gpa.free(at_beta);
    try t.expect(openRaw(ed, at_beta) == null);
    try t.expectEqualStrings("a.txt", ed.bufferName());
    try t.expectEqual(@as(usize, 6), ed.buffers.active().textEditor().?.cursorOffset());
    // Closed, it opens again by the same name — from disk.
    ed.run("buffer-close");
    try t.expect(openRaw(ed, at_beta) == null);
    const text = try ed.textAlloc();
    defer gpa.free(text);
    try t.expectEqualStrings("alpha\nbeta\n", text);

    // A document with no file, closed: kept, and the same document comes
    // back — its text, its id.
    ed.runStr("buffer-create", "*scratch-2*");
    try ed.buffers.active().textEditor().?.insertText(gpa, "kept");
    const doc_name = try gpa.dupe(u8, named(ed));
    defer gpa.free(doc_name);
    const doc_id = ed.buffers.active().textEditor().?.doc.id;
    ed.run("buffer-close-force");
    try t.expect(core.designation.findText(ed.buffers, doc_name) == null);
    try t.expect(openRaw(ed, doc_name) == null);
    try t.expect(ed.buffers.active().textEditor().?.doc.id.eql(doc_id));
    const kept = try ed.textAlloc();
    defer gpa.free(kept);
    try t.expectEqualStrings("kept", kept);

    // A projection with no entry showing it: its producer runs again.
    try t.expect(openRaw(ed, "weft://here/dashboard/main") == null);
    try t.expectEqualStrings("weft://here/dashboard/main", named(ed));
    ed.run("buffer-close");
    try t.expect(core.designation.findText(ed.buffers, "weft://here/dashboard/main") == null);
    try t.expect(openRaw(ed, "weft://here/dashboard/main") == null);
    try t.expectEqualStrings("weft://here/dashboard/main", named(ed));
    // A kind nobody produces is refused by name.
    try t.expectEqualStrings(core.designation.refuse_no_producer, openRaw(ed, "weft://here/nobody.here/x").?);

    // A live process whose entry was closed comes back: reattached, not
    // restarted.
    ed.runStr("repl-start", "cat");
    const repl = try gpa.dupe(u8, named(ed));
    defer gpa.free(repl);
    ed.run("buffer-close");
    try t.expect(core.designation.findText(ed.buffers, repl) == null);
    try t.expect(openRaw(ed, repl) == null);
    try t.expectEqualStrings(repl, named(ed));
    // Once it has exited and its entry is gone, it is refused as gone.
    ed.run("repl-quit");
    ed.run("buffer-close");
    try t.expect(openRaw(ed, repl) != null);
    try t.expect(core.designation.findText(ed.buffers, repl) == null);
}

test "e2e/designation: a document keeps its minted id through a save and a reload — only its name moves to the file" {
    var app: App = undefined;
    try app.init(t.allocator);
    defer app.deinit();
    const ed = &app.ed;
    const gpa = t.allocator;
    var buf: [4096]u8 = undefined;

    ed.runStr("buffer-create", "*draft*");
    const te = ed.buffers.active().textEditor().?;
    try te.insertText(gpa, "draft\n");
    const id = te.doc.id;
    try t.expect(durable.parse(named(ed)).?.docId().?.eql(id));

    // Saved as a file: it is named by the file now, and is the same document.
    const path = try std.fmt.allocPrint(gpa, "{s}/draft.txt", .{app.proj.root});
    defer gpa.free(path);
    _ = try core.command.run(ed.commands, ed.ctx, "save-as", &.{.{ .string = path }});
    ed.waitSave();
    try t.expectEqualStrings(app.under(&buf, "file", "/draft.txt"), named(ed));
    try t.expect(te.doc.id.eql(id));

    // The file changes under it and the change is merged in: still the
    // same document.
    try core.file.writeBytes(gpa, path, "draft\nfrom outside\n");
    try te.requestBackingPoll(gpa);
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    var merged = false;
    while (!merged and core.task.nowNs() < deadline) {
        merged = try te.pollBacking(gpa);
        if (!merged) std.Thread.yield() catch {};
    }
    try t.expect(merged);
    try t.expect(te.doc.id.eql(id));
}

test "e2e/designation: a typed relative name opens against the place, and a malformed designation is not one" {
    var app: App = undefined;
    try app.init(t.allocator);
    defer app.deinit();
    const ed = &app.ed;
    const gpa = t.allocator;
    // A bare name is resolved once, at the door, against the place the
    // command runs in, and what is held afterwards is absolute: the same
    // entry its absolute spelling opens.
    try t.expect(openRaw(ed, "a.txt") == null);
    const opened = ed.buffers.active().textEditor().?.backingPath().?;
    try t.expect(std.fs.path.isAbsolute(opened));
    try t.expectEqualStrings("a.txt", std.fs.path.basename(opened));
    const before = ed.buffers.count();
    try t.expect(openRaw(ed, opened) == null);
    try t.expectEqual(before, ed.buffers.count());
    // A malformed designation opens nothing.
    try t.expect(openRaw(ed, "weft://here/doc/not-an-id") != null);
    try t.expectEqual(before, ed.buffers.count());
    // A viewport SUBJECT is declared in config, where there is no dispatch to
    // take a place from: a relative one is still refused where it is written
    // (`{context: "place"}` is how to say "wherever I am").
    try t.expectError(error.RelativeSubject, ed.session.system.viewports.present(gpa, "nowhere", .{ .subject = .{ .text = "." } }));
}

test "e2e/designation: the jumplist reopens a closed file and a closed scratch document by name" {
    var app: App = undefined;
    try app.init(t.allocator);
    defer app.deinit();
    const ed = &app.ed;
    const gpa = t.allocator;

    ed.runStr("open", "a.txt");
    ed.buffers.active().textEditor().?.placeCursor(6);
    ed.runStr("buffer-create", "*draft*");
    try ed.buffers.active().textEditor().?.insertText(gpa, "draft text");
    const draft_doc = ed.buffers.active().textEditor().?.doc.id;
    ed.buffers.active().textEditor().?.placeCursor(5);
    ed.runStr("open", "sub/inner.txt");
    try t.expectEqualStrings("inner.txt", ed.bufferName());

    // Close both earlier entries. Their jumps keep what they named.
    for ([_][]const u8{ "*draft*", "a.txt" }) |name| {
        const id = ed.buffers.findByName(name) orelse return error.NoEntry;
        ed.runStr("buffer-switch", "");
        _ = try core.command.run(ed.commands, ed.ctx, "buffer-switch", &.{.{ .integer = @intCast(id) }});
        _ = try core.command.run(ed.commands, ed.ctx, "buffer-close-force", &.{});
    }
    try t.expect(ed.buffers.findByName("a.txt") == null);
    try t.expect(ed.buffers.findByName("*draft*") == null);

    // Back along the list: each closed entry is opened again, where it was.
    var saw_draft = false;
    var saw_a = false;
    for (0..8) |_| {
        ed.run("jump-back");
        const b = ed.buffers.active();
        if (b.textEditor()) |te| {
            if (te.doc.id.eql(draft_doc)) {
                saw_draft = true;
                try t.expectEqual(@as(usize, 5), te.cursorOffset());
            }
        }
        if (std.mem.eql(u8, b.name, "a.txt")) {
            saw_a = true;
            try t.expectEqual(@as(usize, 6), b.textEditor().?.cursorOffset());
        }
    }
    try t.expect(saw_draft);
    try t.expect(saw_a);
}

test "e2e/designation: a peer's shared tree opens by designation — the same path as peer-files — titled by the peer's name" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    try core.file.writeBytesMakingDirs(gpa, "shared/src", "shared/src/main.zig", "pub fn main() void {}\n");

    var a: Editor = undefined;
    try Editor.initNamed(gpa, &a, "alice");
    defer a.deinit();
    var b: Editor = undefined;
    try Editor.initNamed(gpa, &b, "bob");
    defer b.deinit();
    try h.loadWebIde(&b); // the files plugin claims directories
    try b.enableCollabCommands();

    // A live, authenticated connection: bob knows alice by her fingerprint.
    var link: h.Loopback = undefined;
    try h.Loopback.init(&link, gpa, &a, &b, "alice", "bob");
    defer link.deinit();
    const fp = link.peer_sess.peerFingerprint() orelse return error.NoHandshake;

    // Stand up alice's shared tree on bob's side the way the collab shell
    // does (`Collab.reconcileRemoteFilesystem`): the remote-filesystem
    // provider under its own authority, speaking the peer_fs protocol to a
    // server over alice's confined root, and that root published as
    // `weft://<fingerprint>/dir/`. Only the transport is in-process; from the
    // protocol up it is the path a real peer's tree takes.
    const system = b.session.system;
    var local = h.fs_platform.Provider.init(gpa);
    defer local.deinit();
    const shared_root = try std.fmt.allocPrint(gpa, "{s}/shared", .{proj.root});
    defer gpa.free(shared_root);
    const alice_root = try local.acquireRoot(shared_root);
    defer local.releaseRoot(alice_root);
    var server = try h.fs_remote.Server.init(gpa, local.provider(), alice_root, .read);
    defer server.deinit();
    const InProcess = struct {
        server: *h.fs_remote.Server,
        pub fn roundTrip(self: *@This(), allocator: std.mem.Allocator, request: []const u8) h.fs.contract.Error![]u8 {
            return self.server.handle(allocator, request);
        }
    };
    var exchange: InProcess = .{ .server = &server };
    var provider = try h.fs_remote.Provider.init(@enumFromInt(77), .init(&exchange));
    const authority = provider.authority;
    try system.filesystems.register(authority, provider.provider());
    defer system.filesystems.unregister(authority) catch {};
    const root = try provider.acquireRoot();
    const owner = try system.semantic.acquireOwner();
    var root_name: [96]u8 = undefined;
    const root_designation = try (durable.Designation{ .authority = .{ .peer = &fp }, .kind = .directory, .ref = "/" }).render(&root_name);
    var publication = try h.fs_runtime.publication.publish(gpa, &system.semantic.targets, &system.filesystems, owner, .{
        .display_name = "peer shared files",
        .directory = .{ .root = root },
        .designation = root_designation,
    });
    b.share_ctx.remote_fs_target = publication.located();
    b.share_ctx.remote_fs_owner = owner;
    b.share_ctx.setPeerLabel("alice.example:7000");
    defer {
        b.share_ctx.closeRemoteChildren(&system.semantic.targets);
        b.share_ctx.remote_children.deinit(gpa);
        if (b.share_ctx.peer_label) |label| gpa.free(label);
        b.share_ctx.peer_label = null;
        b.share_ctx.remote_fs_target = null;
        _ = publication.close(gpa, &system.semantic.targets, &system.filesystems);
        provider.releaseRoot(root);
        _ = system.semantic.releaseOwner(gpa, owner);
    }

    // `peer-files` is `open` of the tree's designation.
    b.run("peer-files");
    b.applyWindow();
    try t.expectEqualStrings(root_designation, named(&b));
    try t.expectEqualStrings("files: alice.example:/", b.bufferName());

    // A directory below it, by designation: looked up in the peer's own
    // listing, presented the same way, titled by the peer's name.
    var sub_name: [128]u8 = undefined;
    const src_designation = try (durable.Designation{ .authority = .{ .peer = &fp }, .kind = .directory, .ref = "/src" }).render(&sub_name);
    try t.expect(openRaw(&b, src_designation) == null);
    try t.expectEqualStrings(src_designation, named(&b));
    try t.expectEqualStrings("files: alice.example:/src", b.bufferName());
    // Nothing the peer does not have.
    try t.expect(openRaw(&b, "weft://" ++ "nobody" ++ "/dir/src") != null);
    // A peer's file opens READ-ONLY, read once through the peer's tree and
    // named by what it is: there is no remote file backing to write through
    // (editing it together is sharing it as a document).
    var file_name: [128]u8 = undefined;
    const file_designation = try (durable.Designation{ .authority = .{ .peer = &fp }, .kind = .file, .ref = "/src/main.zig" }).render(&file_name);
    try t.expect(openRaw(&b, file_designation) == null);
    try t.expectEqualStrings(file_designation, named(&b));
    try t.expect(b.buffers.active().read_only);
    // One the peer does not have is refused by name.
    var missing_name: [128]u8 = undefined;
    const missing = try (durable.Designation{ .authority = .{ .peer = &fp }, .kind = .file, .ref = "/src/nope.zig" }).render(&missing_name);
    try t.expect(std.mem.indexOf(u8, openRaw(&b, missing).?, "no such file") != null);
}

/// Run a command and copy its string result.
fn result(ed: *Editor, buf: []u8, cmd: []const u8, args: []const core.command.Value) []const u8 {
    const v = core.command.run(ed.commands, ed.ctx, cmd, args) catch return "";
    const s = switch (v) {
        .string => |s| s,
        else => return "",
    };
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

test "e2e/designation: a listing's title follows its designation through a step out, absolute throughout" {
    var app: App = undefined;
    try app.init(t.allocator);
    defer app.deinit();
    const ed = &app.ed;
    var buf: [4096]u8 = undefined;

    ed.runStr("open", "sub");
    try t.expectEqualStrings(app.under(&buf, "dir", "/sub"), named(ed));
    // Up to the containing directory: the same entry now IS the project's
    // root, and reads as its absolute display form — never a leaf, never ".".
    ed.run("hierarchy-step-out");
    ed.applyWindow();
    try t.expectEqualStrings(app.under(&buf, "dir", ""), named(ed));
    var title: [4096]u8 = undefined;
    const want = core.designation.title(&title, "files", named(ed), "", null);
    try t.expectEqualStrings(want, ed.bufferName());
    try t.expect(!std.mem.eql(u8, ed.bufferName(), "files: ."));
}

test "e2e/designation: the guest doors — read an entry's name, declare only what the plugin may say" {
    var app: App = undefined;
    try app.init(t.allocator);
    defer app.deinit();
    const ed = &app.ed;
    try h.loadOfferwatch(ed);
    var buf: [4096]u8 = undefined;
    var want: [4096]u8 = undefined;

    // `weft.designation()` reads what core derives.
    ed.runStr("open", "a.txt");
    try t.expectEqualStrings(app.under(&want, "file", "/a.txt"), result(ed, &buf, "ow-designation", &.{}));
    // A file is named by its file: nothing overrides that.
    try t.expectEqualStrings("refused", result(ed, &buf, "ow-designate", &.{.{ .string = "weft://here/proc/mine" }}));

    // The user's own scratch is no plugin's to re-declare: not as a process
    // (closing it would then destroy the text), and not by clearing either.
    ed.runStr("buffer-create", "*mine*");
    try t.expectEqualStrings("refused", result(ed, &buf, "ow-designate", &.{.{ .string = "weft://here/proc/ow.1" }}));
    try t.expectEqualStrings("refused", result(ed, &buf, "ow-designate", &.{.{ .string = "" }}));
    try t.expect(ed.buffers.active().designation.len == 0);

    // On a scratch entry it made: no plugin may say it is a file or a document…
    _ = result(ed, &buf, "ow-create", &.{.{ .string = "*produced*" }});
    try t.expectEqualStrings("*produced*", ed.bufferName());
    try t.expectEqualStrings("refused", result(ed, &buf, "ow-designate", &.{.{ .string = "weft://here/file/etc/passwd" }}));
    try t.expectEqualStrings("refused", result(ed, &buf, "ow-designate", &.{.{ .string = "weft://here/doc/000102030405060708090a0b0c0d0e0f" }}));
    // …nor another producer's projection (the dashboard's is claimed)…
    try t.expectEqualStrings("refused", result(ed, &buf, "ow-designate", &.{.{ .string = "weft://here/dashboard/main" }}));
    try t.expectEqualStrings("refused", result(ed, &buf, "ow-claim", &.{ .{ .string = "dashboard" }, .{ .string = "x" } }));
    // …nor claim a grammar kind; nor a process in a namespace another
    // plugin reattaches.
    try t.expectEqualStrings("refused", result(ed, &buf, "ow-claim", &.{ .{ .string = "file" }, .{ .string = "x" } }));
    try t.expectEqualStrings("refused", result(ed, &buf, "ow-designate", &.{.{ .string = "weft://here/proc/repl.9" }}));
    // Its own projection kind, claimed, it may declare — and then `open`
    // finds the entry by it.
    try t.expectEqualStrings("ok", result(ed, &buf, "ow-claim", &.{ .{ .string = "offerwatch.probe" }, .{ .string = "ow-probe" } }));
    try t.expectEqualStrings("ok", result(ed, &buf, "ow-designate", &.{.{ .string = "weft://here/offerwatch.probe/one" }}));
    try t.expectEqualStrings("weft://here/offerwatch.probe/one", named(ed));
    const produced = ed.buffers.active_id;
    ed.runStr("open", "a.txt");
    try t.expect(openRaw(ed, "weft://here/offerwatch.probe/one") == null);
    try t.expectEqual(produced, ed.buffers.active_id);
}

test "e2e/designation: a place is named by its designation — the builtin reads it, and a publisher retracts from elsewhere by it" {
    var app: App = undefined;
    try app.init(t.allocator);
    defer app.deinit();
    const ed = &app.ed;
    try h.loadOfferwatch(ed);
    var buf: [4096]u8 = undefined;

    ed.runStr("open", "a.txt");
    ed.applyWindow();
    // The `entry` and `place` builtins are designations now.
    const facts = core.intent.factsFor(ed.ctx);
    var want: [4096]u8 = undefined;
    try t.expectEqualStrings(app.under(&want, "file", "/a.txt"), facts.get("entry").?);
    const place = facts.get("place") orelse return error.NoPlace;
    try t.expect(std.mem.startsWith(u8, place, "weft://here/dir/"));
    const place_owned = try t.allocator.dupe(u8, place);
    defer t.allocator.free(place_owned);

    // Published at this place, named — then retracted by the same name from
    // an entry somewhere else entirely.
    try t.expectEqualStrings("ok", result(ed, &buf, "ow-context-set-at", &.{ .{ .string = "offerwatch.session" }, .{ .string = "live" }, .{ .string = place_owned } }));
    try t.expectEqualStrings("live", core.intent.factsFor(ed.ctx).get("offerwatch.session").?);
    // Another project: its own marker makes it its own place.
    try core.file.writeBytesMakingDirs(t.allocator, "other/.git", "other/.git/HEAD", "ref: refs/heads/main\n");
    try core.file.writeBytes(t.allocator, "other/b.txt", "b\n");
    ed.runStr("open", "other/b.txt");
    ed.applyWindow();
    try t.expectEqualStrings(app.under(&want, "dir", "/other"), core.intent.factsFor(ed.ctx).get("place").?);
    try t.expect(core.intent.factsFor(ed.ctx).get("offerwatch.session") == null); // not published here
    try t.expectEqualStrings("ok", result(ed, &buf, "ow-context-set-at", &.{ .{ .string = "offerwatch.session" }, .{ .string = "" }, .{ .string = place_owned } }));
    ed.runStr("open", "a.txt");
    try t.expect(core.intent.factsFor(ed.ctx).get("offerwatch.session") == null);
    // Only a directory names a place.
    try t.expectEqualStrings("refused", result(ed, &buf, "ow-context-set-at", &.{ .{ .string = "offerwatch.session" }, .{ .string = "v" }, .{ .string = "weft://here/proc/x" } }));
}

test "e2e/designation: a scratch document outlives the process and opens by its name in the next one" {
    const gpa = t.allocator;
    // A private state directory, armed the way main.zig arms it, around two
    // whole editors booted one after the other: the second is the next run.
    const dir = try core.kv_file.testDir(gpa, "e2e-documents");
    defer gpa.free(dir);
    defer core.kv_file.removeTestDir(gpa, dir); // LIFO: after the file is gone
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, core.kv_file.documents_file });
    defer gpa.free(path);
    core.file.deleteFile(gpa, path);
    defer core.file.deleteFile(gpa, path);

    var name_buf: [durable.DocId.text_len + 32]u8 = undefined;
    const name = blk: {
        var app: App = undefined;
        try app.init(gpa);
        defer app.deinit();
        const ed = &app.ed;
        var documents = core.Buffers.DocumentFile.openIn(gpa, ed.buffers, try gpa.dupe(u8, dir));
        ed.runStr("buffer-create", "*draft*");
        try ed.buffers.active().textEditor().?.insertText(gpa, "written last run\n");
        const spelled = ed.buffers.active().textEditor().?.doc.id.text();
        // Shutdown: the draft is still open, and is kept.
        documents.close();
        break :blk try std.fmt.bufPrint(&name_buf, "weft://here/doc/{s}", .{&spelled});
    };

    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    var documents = core.Buffers.DocumentFile.openIn(gpa, ed.buffers, try gpa.dupe(u8, dir));
    defer documents.close();
    // Nothing is reopened at startup…
    try t.expect(ed.buffers.findByName("*draft*") == null);
    // …and `open` of its designation brings it back, name and text.
    try t.expect(openRaw(ed, name) == null);
    try t.expectEqualStrings("*draft*", ed.bufferName());
    try t.expectEqualStrings(name, named(ed));
    const te = ed.buffers.active().textEditor().?;
    var text: [64]u8 = undefined;
    const len = te.text().byteLen();
    var sr = te.text().streamReader(.{ .start = 0, .end = len }, &.{});
    try sr.interface.readSliceAll(text[0..len]);
    try t.expectEqualStrings("written last run\n", text[0..len]);
}

/// A JS producer: the designation doors, the context event and a subject
/// watch, through the same bodies a `.wasm` plugin reaches (doc/model.md
/// §3.5: JS plugins had none of them).
const js_producer =
    \\weft.designationOpener("jsp.probe", "jsp-probe");
    \\var keys = [];
    \\var subjects = [];
    \\weft.onContextChanged(function (k) { keys = keys.concat(k); });
    \\weft.onSubjectChanged(function (d) { subjects.push(d + "#" + weft.byteLen()); });
    \\weft.command("jsp-probe", function () {});
    \\weft.command("jsp-name", function () { weft.echo(weft.designation() || "none"); });
    \\weft.command("jsp-make", function () {
    \\  weft.run("buffer-create", "*jsmade*");
    \\  weft.echo(weft.designate("weft://here/jsp.probe/one") ? "ok" : "refused");
    \\});
    \\weft.command("jsp-foreign", function () { weft.echo(weft.designate("weft://here/jsp.probe/two") ? "ok" : "refused"); });
    \\weft.command("jsp-steal", function () { weft.echo(weft.designationOpener("dashboard", "x") ? "ok" : "refused"); });
    \\weft.command("jsp-watch", function () { weft.echo(weft.subjectWatch(weft.designation()) ? "ok" : "refused"); });
    \\weft.command("jsp-keys", function () { weft.echo(keys.indexOf("entry") >= 0 ? "entry" : "none"); keys = []; });
    \\weft.command("jsp-subjects", function () { weft.echo(subjects.length ? subjects.join(",") : "(none)"); subjects = []; });
;

test "e2e/designation: a JS plugin reads and declares designations and claims a kind under the wasm rules" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try ed.loadJs("jsp", js_producer);

    // It reads what core derives.
    ed.runStr("buffer-create", "*mine*");
    ed.run("jsp-name");
    const doc = ed.buffers.active().textEditor().?.doc.id.text();
    var want: [64]u8 = undefined;
    try t.expectEqualStrings(try std.fmt.bufPrint(&want, "weft://here/doc/{s}", .{&doc}), ed.echoText());
    // The user's entry is not its to re-declare: the creator rule.
    ed.run("jsp-foreign");
    try t.expectEqualStrings("refused", ed.echoText());
    try t.expect(ed.buffers.active().designation.len == 0);
    // An entry it made, in the kind it claimed at load, it may declare — and
    // `open` finds the entry by it.
    ed.run("jsp-make");
    try t.expectEqualStrings("ok", ed.echoText());
    try t.expectEqualStrings("*jsmade*", ed.bufferName());
    try t.expectEqualStrings("jsp", ed.buffers.active().creator);
    try t.expectEqualStrings("weft://here/jsp.probe/one", ed.buffers.active().designationText());
    const made = ed.buffers.active_id;
    ed.runStr("buffer-create", "*elsewhere*");
    ed.runStr("open", "weft://here/jsp.probe/one");
    try t.expectEqual(made, ed.buffers.active_id);
    // A kind outside its name is not its to claim (and a JS plugin declares
    // no capabilities to widen that).
    ed.run("jsp-steal");
    try t.expectEqualStrings("refused", ed.echoText());
}

test "e2e/designation: a JS plugin whose load claims a kind outside its name fails to load, as a wasm one does" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try t.expectError(error.DesignationKindRefused, ed.loadJs("jsbad", "weft.designationOpener(\"other.kind\", \"x\");"));
    // Nothing it said outlives the failed load.
    try t.expect(ed.ctx.designations.?.find("other.kind") == null);
}

test "e2e/designation: a JS plugin hears the context move and its watched subject change, bound to the subject" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try ed.loadJs("jsp", js_producer);

    ed.runStr("buffer-create", "*subject*");
    const subject = ed.buffers.active();
    ed.run("jsp-watch");
    try t.expectEqualStrings("ok", ed.echoText());
    ed.run("jsp-name");
    var name_buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{s}", .{ed.echoText()});

    // Moving to another entry moves the `entry` key: onContextChanged hears it.
    ed.runStr("buffer-create", "*other*");
    ed.applyWindow();
    ed.run("jsp-keys");
    try t.expectEqualStrings("entry", ed.echoText());

    // The subject changes while another entry is in front: the handler is
    // told once, bound to the subject — its reads are the subject's.
    const doc = &subject.textEditor().?.doc;
    try doc.insert(gpa, 0, "four");
    try doc.insert(gpa, 4, "56");
    ed.applyWindow();
    ed.run("jsp-subjects");
    var want: [160]u8 = undefined;
    try t.expectEqualStrings(try std.fmt.bufPrint(&want, "{s}#6", .{name}), ed.echoText());
    // Nothing moved since: nothing is delivered.
    ed.applyWindow();
    ed.run("jsp-subjects");
    try t.expectEqualStrings("(none)", ed.echoText());
}
