//! e2e test file — chrome as projections (doc/model.md §2.3–2.5, phase 3):
//! a viewport's subject is a designation or ONE context key, `as` picks the
//! projection, `reveal` highlights inside it without taking focus — and the
//! sidebar, the outline, the problems list and the places list are nothing
//! but that composition, in config.
//!
//! Driven through the shipped configs (ide.js docks the sidebar and the
//! toolbar; the outline is a fragment the test imports the way a person's
//! config would), the peer case through the two-peer harness the designation
//! gates use.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const ide = @import("ide_test.zig");
const lang = @import("language_support.zig");

const core = h.core;
const semantic_model = h.semantic_model;
const window_layout = h.window_layout;
const Editor = h.Editor;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;
const IdeApp = ide.IdeApp;
const durable = core.designation.durable;

/// `weft://here/<kind><root><rest>` for this project.
fn under(proj: *Project, buf: []u8, kind: []const u8, rest: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "weft://here/{s}{s}{s}", .{ kind, proj.root, rest }) catch unreachable;
}

pub fn sidebarPane(ed: *Editor) !*window_layout.Node {
    return ed.win_layout.dockedPanel(.left) orelse error.NoSidebar;
}

pub fn paneEntry(ed: *Editor, pane: *window_layout.Node) !*core.Buffers.Buffer {
    return ed.buffers.get(pane.pane().buffer_id) orelse error.NoEntry;
}

/// What the sidebar lists: the designation of the entry it shows.
pub fn sidebarShows(ed: *Editor) ![]const u8 {
    return (try paneEntry(ed, try sidebarPane(ed))).designationText();
}

/// The designation of the row the sidebar's view reveals — the node its
/// revealed highlight names (never its selection), through the target that
/// row links (whose name its trusted publisher bound: the parent's plus the
/// provider's leaf).
pub fn sidebarHighlights(ed: *Editor) ?[]const u8 {
    const pane = sidebarPane(ed) catch return null;
    const entry = paneEntry(ed, pane) catch return null;
    const views = &ed.session.system.semantic.views;
    const shown = if (entry.id == ed.buffers.active_id) ed.head.scene_selection.view else entry.scene_selection.view;
    const view = shown orelse entry.tool_view orelse return null;
    const instance = views.get(view) orelse return null;
    const node = instance.node(views.revealed(view) orelse return null) orelse return null;
    const link = node.target orelse return null;
    return ed.session.system.filesystems.designationOf(link.target, link.revision);
}

fn files(ed: *Editor) usize {
    var n: usize = 0;
    var it = ed.buffers.iterator();
    while (it.next()) |b| if (std.mem.eql(u8, b.tool, "files")) {
        n += 1;
    };
    return n;
}

pub fn makeProjects(gpa: std.mem.Allocator) !void {
    try core.file.writeBytes(gpa, "a.txt", "alpha\n");
    try core.file.writeBytesMakingDirs(gpa, "sub", "sub/inner.txt", "INNER\n");
    // Another project: its own marker makes it its own place.
    try core.file.writeBytesMakingDirs(gpa, "other/.git", "other/.git/HEAD", "ref: refs/heads/main\n");
    try core.file.writeBytes(gpa, "other/b.txt", "bee\n");
}

test "e2e/projection: the sidebar presents the place, keeps what you navigate to until the place moves, then follows it" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try makeProjects(gpa);
    var buf: [4096]u8 = undefined;

    ed.runStr("file.open", "a.txt");
    ed.applyWindow();
    // The subject is the `place` key's value: this project's directory.
    try t.expectEqualStrings(under(&app.proj, &buf, "dir", ""), try sidebarShows(ed));

    // Navigate inside the sidebar: the keys go there, and it steps out to
    // the directory above the project.
    const pane = try sidebarPane(ed);
    const view = try ed.ensureView();
    const row = for (view.pane_maps[0..view.pane_map_count]) |m| {
        if (m.pane == pane.pane().id and m.hits.len > 0) break m.hits[0];
    } else return error.SidebarNotDrawn;
    ed.click(.{ row.rect.x + 2, row.rect.y + row.rect.h / 2 });
    ed.applyWindow();
    try t.expectEqual(pane.pane().buffer_id, ed.buffers.active_id);
    ed.run("target.open-container");
    ed.applyWindow();
    const parent = std.fs.path.dirname(app.proj.root).?;
    const stepped = try std.fmt.allocPrint(gpa, "weft://here/dir{s}", .{parent});
    defer gpa.free(stepped);
    try t.expectEqualStrings(stepped, try sidebarShows(ed));
    const navigated = (try paneEntry(ed, pane)).ref();

    // Another file in the SAME place: the entry key moved, the place key did
    // not — so the sidebar is not presented again, and keeps what you
    // navigated to. The reveal still finds the file inside it, opening the
    // folders on the way.
    ed.runStr("file.open", "sub/inner.txt");
    ed.applyWindow();
    try t.expectEqual(navigated, (try paneEntry(ed, pane)).ref());
    try t.expectEqualStrings(stepped, try sidebarShows(ed));
    try t.expectEqualStrings(under(&app.proj, &buf, "file", "/sub/inner.txt"), sidebarHighlights(ed) orelse return error.NothingRevealed);

    // Another project: the place moved, so the sidebar presents it — and the
    // listing the last presentation made is closed, not left behind as a tab.
    const before = files(ed);
    ed.runStr("file.open", "other/b.txt");
    ed.applyWindow();
    try t.expectEqualStrings(under(&app.proj, &buf, "dir", "/other"), try sidebarShows(ed));
    try t.expectEqualStrings(under(&app.proj, &buf, "file", "/other/b.txt"), sidebarHighlights(ed) orelse return error.NothingRevealed);
    try t.expectEqual(before, files(ed));
    try t.expect(ed.buffers.resolve(navigated) == null);
}

test "e2e/projection: a following sidebar never discards a draft — the listing holding one stays, as a tab" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try makeProjects(gpa);
    var buf: [4096]u8 = undefined;

    ed.runStr("file.open", "a.txt");
    ed.applyWindow();
    // Into the sidebar, and delete a row there: a draft, not yet applied (a
    // delete asks before it applies, whatever ends the gesture).
    const pane = try sidebarPane(ed);
    const view = try ed.ensureView();
    const row = for (view.pane_maps[0..view.pane_map_count]) |m| {
        if (m.pane == pane.pane().id and m.hits.len > 0) break m.hits[0];
    } else return error.SidebarNotDrawn;
    ed.click(.{ row.rect.x + 2, row.rect.y + row.rect.h / 2 });
    ed.applyWindow();
    const listing = (try paneEntry(ed, pane)).ref();
    try t.expectEqual(listing.id, ed.buffers.active_id);
    try ed.focusFilesName("a.txt");
    ed.press("Escape", ""); // the entered edit ends; the row stays focused
    ed.press("Delete", "");
    const listing_view = ed.toolView() orelse return error.NoFilesView;
    try t.expect(ed.session.system.semantic.holdsDraft(listing_view));

    // Another project: the sidebar follows it…
    ed.runStr("file.open", "other/b.txt");
    ed.applyWindow();
    try t.expectEqualStrings(under(&app.proj, &buf, "dir", "/other"), try sidebarShows(ed));
    // …and the listing holding the draft is still an entry, the draft in it.
    try t.expect(ed.buffers.resolve(listing) != null);
    try t.expect(ed.session.system.semantic.holdsDraft(listing_view));
    // Nothing was applied: the file is still there.
    try t.expectEqual(core.file.Kind.file, core.file.statKind(gpa, "a.txt"));
}

test "e2e/projection: the reveal highlights the editor's entry in the sidebar without taking focus" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try makeProjects(gpa);
    var buf: [4096]u8 = undefined;

    ed.runStr("file.open", "a.txt");
    ed.applyWindow();
    const primary = ed.win_layout.primaryPane() orelse return error.NoPrimaryPane;
    ed.runStr("file.open", "sub/inner.txt");
    ed.applyWindow();
    // The folder above it is open, and its row is the listing's highlight…
    try t.expectEqualStrings(under(&app.proj, &buf, "file", "/sub/inner.txt"), sidebarHighlights(ed) orelse return error.NothingRevealed);
    // …while the keys, the active entry and the primary context stay on the
    // editor: revealing is not navigating.
    try t.expectEqual(primary, window_layout.headFocus(ed.win_layout, ed.head));
    try t.expectEqualStrings("inner.txt", std.fs.path.basename(ed.buffers.active().textEditor().?.backingPath().?));
    try t.expectEqual(primary.pane().id, ed.head.primary_focus.?.pane);
    try t.expectEqualStrings("ide", ed.mode());
    ed.typeText("x");
    try ide.expectText(ed, "xINNER\n");
    app.proj.shot(ed, "projection-sidebar-reveal");
}

test "e2e/projection: a key with no value presents an explicit empty state, never the stale subject" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try makeProjects(gpa);

    // A panel following `repl.session`, declared the way a config does.
    const viewports = &ed.session.system.viewports;
    try viewports.declare(gpa, "repl-panel", .{ .dock = .bottom, .persistent = true, .cycles = false, .focus_source = false }, .{ .rows = 6 });
    try viewports.present(gpa, "repl-panel", .{ .subject = .{ .text = "repl.session", .key = true } });
    ed.runStr("file.open", "a.txt");
    ed.applyWindow();
    const panel = ed.win_layout.dockedPanel(.bottom) orelse return error.NoPanel;
    const empty = try paneEntry(ed, panel);
    try t.expectEqualStrings("viewport.empty", empty.tool);
    const empty_text = try ed.semanticText(empty.tool_view.?);
    defer gpa.free(empty_text);
    try t.expect(std.mem.indexOf(u8, empty_text, "repl.session") != null);

    // The repl publishes the key: the panel presents what it names.
    ed.runStr("repl.start", "cat");
    ed.runStr("file.open", "a.txt");
    ed.applyWindow();
    try t.expectEqualStrings("weft://here/proc/repl", (try paneEntry(ed, panel)).designationText());
    // The empty state went with it: it is the viewport's, never a tab.
    var it = ed.buffers.iterator();
    while (it.next()) |b| try t.expect(!std.mem.eql(u8, b.tool, "viewport.empty"));

    // Retracted: the empty state again — not the REPL it showed a moment ago.
    ed.run("repl.quit");
    ed.applyWindow();
    try t.expectEqualStrings("viewport.empty", (try paneEntry(ed, panel)).tool);
}

test "e2e/projection: the outline follows the entry, as the symbols projection of it" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{app.proj.prev_cwd});
    defer gpa.free(config_dir);
    try core.quickjs.evalConfig(&ed.engine, ed.ctx, app.loader.loader(), &ed.config_kv, config_dir, "weft.use(\"outline\");");

    // Two sources. An open presents at once — before its parse lands — and
    // the outline hears the tree land (it watches its subject), so once
    // tools.zig's tree is in, one boundary shows its symbols.
    try ide.openFile(ed, "shapes.zig", "const Point = struct {\n    fn norm(self: Point) u32 {\n        return 0;\n    }\n};\n");
    try t.expect(lang.waitForTree(ed, lang.attachedSyntax(ed) orelse return error.NoSyntax));
    try ide.openFile(ed, "tools.zig", "fn hammer() void {}\nfn saw() void {}\n");
    try t.expect(lang.waitForTree(ed, lang.attachedSyntax(ed) orelse return error.NoSyntax));
    ed.applyWindow();

    const outline = ed.win_layout.dockedPanel(.right) orelse return error.NoOutline;
    {
        const entry = try paneEntry(ed, outline);
        const text = try ed.semanticText(entry.scene_selection.view.?);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "hammer") != null);
        try t.expect(std.mem.indexOf(u8, text, "saw") != null);
        try t.expect(std.mem.indexOf(u8, text, "Point") == null);
    }
    // Back to the other entry: its symbols, nested.
    ed.runStr("file.open", "shapes.zig");
    ed.applyWindow();
    {
        const entry = try paneEntry(ed, outline);
        const text = try ed.semanticText(entry.scene_selection.view.?);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "Point") != null);
        try t.expect(std.mem.indexOf(u8, text, "norm") != null);
        // Nested inside the struct that encloses it.
        try t.expectEqualStrings("1", symbolDepth(ed, entry.scene_selection.view.?, "norm") orelse return error.NoNorm);
        try t.expectEqualStrings("0", symbolDepth(ed, entry.scene_selection.view.?, "Point") orelse return error.NoPoint);
        try t.expect(std.mem.indexOf(u8, text, "hammer") == null);
        try t.expect(std.mem.startsWith(u8, entry.designationText(), "weft://here/symbols/file/"));
    }
    app.proj.shot(ed, "projection-outline");
}

test "e2e/projection: the outline hears its subject change — an edit and a later parse — without presenting it again" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{app.proj.prev_cwd});
    defer gpa.free(config_dir);
    try core.quickjs.evalConfig(&ed.engine, ed.ctx, app.loader.loader(), &ed.config_kv, config_dir, "weft.use(\"outline\");");

    try ide.openFile(ed, "tools.zig", "fn hammer() void {}\n");
    try t.expect(lang.waitForTree(ed, lang.attachedSyntax(ed) orelse return error.NoSyntax));
    ed.applyWindow();
    const outline = ed.win_layout.dockedPanel(.right) orelse return error.NoOutline;
    const tree = try paneEntry(ed, outline);
    try t.expect(try outlineHas(ed, tree, "hammer"));
    try t.expect(!try outlineHas(ed, tree, "drill"));

    // An edit to the subject: the same tree entry (nothing presented it
    // again) shows the new symbol after one boundary.
    const doc = &ide.textEd(ed).doc;
    try doc.insert(gpa, doc.text().byteLen(), "fn drill() void {}\n");
    ed.applyWindow();
    try t.expectEqual(tree.id, outline.pane().buffer_id);
    try t.expect(try outlineHas(ed, tree, "drill"));

    // A boundary with nothing new re-reads nothing: the view's revision
    // stays where the edit left it.
    const view = tree.scene_selection.view orelse return error.NoOutlineView;
    const revision = ed.session.system.semantic.views.get(view).?.descriptor.revision;
    ed.applyWindow();
    ed.applyWindow();
    try t.expectEqual(revision, ed.session.system.semantic.views.get(view).?.descriptor.revision);
}

/// Whether the outline entry `tree` lists a symbol named `name`.
fn outlineHas(ed: *Editor, tree: *core.Buffers.Buffer, name: []const u8) !bool {
    const text = try ed.semanticText(tree.scene_selection.view orelse return error.NoOutlineView);
    defer ed.gpa.free(text);
    return std.mem.indexOf(u8, text, name) != null;
}

test "e2e/projection: two viewports on two entries' symbols each keep their own tree" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{app.proj.prev_cwd});
    defer gpa.free(config_dir);
    try core.quickjs.evalConfig(&ed.engine, ed.ctx, app.loader.loader(), &ed.config_kv, config_dir, "weft.use(\"outline\");");

    try ide.openFile(ed, "shapes.zig", "const Point = struct {\n    fn norm(self: Point) u32 {\n        return 0;\n    }\n};\n");
    try t.expect(lang.waitForTree(ed, lang.attachedSyntax(ed) orelse return error.NoSyntax));
    try ide.openFile(ed, "tools.zig", "fn hammer() void {}\nfn saw() void {}\n");
    try t.expect(lang.waitForTree(ed, lang.attachedSyntax(ed) orelse return error.NoSyntax));

    // A second viewport pinned to shapes.zig's symbols, beside the outline
    // that follows the editor (on tools.zig).
    var buf: [4096]u8 = undefined;
    const shapes = under(&app.proj, &buf, "file", "/shapes.zig");
    const viewports = &ed.session.system.viewports;
    try viewports.declare(gpa, "pinned-symbols", .{ .dock = .top, .persistent = true, .cycles = false, .focus_source = false }, .{ .rows = 6 });
    try viewports.present(gpa, "pinned-symbols", .{ .subject = .{ .text = shapes }, .as = "symbols" });
    ed.applyWindow();
    ed.applyWindow();

    const outline = ed.win_layout.dockedPanel(.right) orelse return error.NoOutline;
    const pinned = ed.win_layout.dockedPanel(.top) orelse return error.NoPinned;
    const follows = try paneEntry(ed, outline);
    const fixed = try paneEntry(ed, pinned);
    try t.expect(follows.id != fixed.id);
    try t.expect(std.mem.endsWith(u8, follows.designationText(), "/tools.zig"));
    try t.expect(std.mem.endsWith(u8, fixed.designationText(), "/shapes.zig"));
    {
        const text = try ed.semanticText(fixed.scene_selection.view orelse return error.NoPinnedView);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "Point") != null);
        try t.expect(std.mem.indexOf(u8, text, "hammer") == null);
    }
    {
        const text = try ed.semanticText(follows.scene_selection.view orelse return error.NoOutlineView);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "hammer") != null);
        try t.expect(std.mem.indexOf(u8, text, "Point") == null);
    }
    // Another frame presents neither again.
    const ids = .{ follows.id, fixed.id };
    ed.applyWindow();
    try t.expectEqual(ids[0], outline.pane().buffer_id);
    try t.expectEqual(ids[1], pinned.pane().buffer_id);

    // A row of the pinned tree jumps to ITS subject, not the followed one.
    const view = try ed.ensureView();
    const row = for (view.pane_maps[0..view.pane_map_count]) |m| {
        if (m.pane == pinned.pane().id and m.hits.len > 0) break m.hits[0];
    } else return error.PinnedNotDrawn;
    ed.click(.{ row.rect.x + 2, row.rect.y + row.rect.h / 2 });
    ed.press("Return", "");
    ed.applyWindow();
    try t.expectEqualStrings(shapes, ed.buffers.get(ed.win_layout.primaryPane().?.pane().buffer_id).?.designationText());
}

/// How deep the outline row named `name` sits (its `depth` fact).
fn symbolDepth(ed: *Editor, view: semantic_model.view.Ref, name: []const u8) ?[]const u8 {
    const instance = ed.session.system.semantic.views.get(view) orelse return null;
    for (instance.scene.content.container.children) |line| {
        const cells = switch (line.content) {
            .container => |c| c.children,
            else => continue,
        };
        for (cells) |cell| switch (cell.content) {
            .action => |a| if (std.mem.eql(u8, a.label, name)) {
                for (cell.facts) |f| if (std.mem.eql(u8, f.name, "depth")) return f.value;
            },
            else => {},
        };
    }
    return null;
}

/// A peer's shared tree stood up on `b`'s side the way the collab shell does
/// (`Collab.reconcileRemoteFilesystem`) — the remote-filesystem provider
/// under its own authority, speaking the peer_fs protocol to a server over
/// the peer's confined root — as designation_test's peer gate builds it.
pub const PeerTree = struct {
    local: h.fs_platform.Provider,
    alice_root: h.fs.contract.Root,
    server: h.fs_remote.Server,
    exchange: InProcess,
    provider: h.fs_remote.Provider,
    root: h.fs.contract.Root,
    owner: semantic_model.owner.Id,
    publication: h.fs_runtime.publication.Registration,
    root_name: [96]u8,
    root_designation: []const u8,

    const InProcess = struct {
        server: *h.fs_remote.Server,
        pub fn roundTrip(self: *@This(), allocator: std.mem.Allocator, request: []const u8) h.fs.contract.Error![]u8 {
            return self.server.handle(allocator, request);
        }
    };

    pub fn init(self: *PeerTree, gpa: std.mem.Allocator, b: *Editor, shared: []const u8, fp: []const u8) !void {
        return self.initGranting(gpa, b, shared, fp, .read);
    }

    /// `init`, the peer granting `access` over its tree.
    pub fn initGranting(self: *PeerTree, gpa: std.mem.Allocator, b: *Editor, shared: []const u8, fp: []const u8, access: h.fs_remote.Access) !void {
        const system = b.session.system;
        self.local = h.fs_platform.Provider.init(gpa);
        self.alice_root = try self.local.acquireRoot(shared);
        self.server = try h.fs_remote.Server.init(gpa, self.local.provider(), self.alice_root, access);
        self.exchange = .{ .server = &self.server };
        self.provider = try h.fs_remote.Provider.init(@enumFromInt(77), .init(&self.exchange));
        try system.filesystems.register(self.provider.authority, self.provider.provider());
        self.root = try self.provider.acquireRoot();
        self.owner = try system.semantic.acquireOwner();
        self.root_designation = try (durable.Designation{ .authority = .{ .peer = fp }, .kind = .directory, .ref = "/" }).render(&self.root_name);
        self.publication = try h.fs_runtime.publication.publish(gpa, &system.semantic.targets, &system.filesystems, self.owner, .{
            .display_name = "peer shared files",
            .directory = .{ .root = self.root },
            .designation = self.root_designation,
        });
        b.share_ctx.remote_fs_target = self.publication.located();
        b.share_ctx.remote_fs_owner = self.owner;
        b.share_ctx.setPeerLabel("alice.example:7000");
    }

    pub fn deinit(self: *PeerTree, gpa: std.mem.Allocator, b: *Editor) void {
        const system = b.session.system;
        b.share_ctx.closeRemoteChildren(&system.semantic.targets);
        b.share_ctx.remote_children.deinit(gpa);
        if (b.share_ctx.peer_label) |label| gpa.free(label);
        b.share_ctx.peer_label = null;
        b.share_ctx.remote_fs_target = null;
        _ = self.publication.close(gpa, &system.semantic.targets, &system.filesystems);
        self.provider.releaseRoot(self.root);
        _ = system.semantic.releaseOwner(gpa, self.owner);
        system.filesystems.unregister(self.provider.authority) catch {};
        self.server.deinit();
        self.local.releaseRoot(self.alice_root);
        self.local.deinit();
    }
};

test "e2e/projection: the sidebar follows local, another local project, then a peer's shared tree — and reveals the file there" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    try makeProjects(gpa);
    try core.file.writeBytesMakingDirs(gpa, "shared/src", "shared/src/main.zig", "pub fn main() void {}\n");
    var buf: [4096]u8 = undefined;

    var a: Editor = undefined;
    try Editor.initNamed(gpa, &a, "alice");
    defer a.deinit();
    var b: Editor = undefined;
    try Editor.initNamed(gpa, &b, "bob");
    defer b.deinit();
    var loader: ConfigLoader = .{ .ed = &b };
    defer loader.deinit();
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);
    try h.bootConfigNamed(&b, config_dir, "ide.js", &loader);
    try b.buffers.setDefaultMode(gpa, b.head.currentMode());
    try b.enableCollabCommands();

    var link: h.Loopback = undefined;
    try h.Loopback.init(&link, gpa, &a, &b, "alice", "bob");
    defer link.deinit();
    const fp = link.peer_sess.peerFingerprint() orelse return error.NoHandshake;
    const shared_root = try std.fmt.allocPrint(gpa, "{s}/shared", .{proj.root});
    defer gpa.free(shared_root);
    var tree: PeerTree = undefined;
    try tree.init(gpa, &b, shared_root, &fp);
    defer tree.deinit(gpa, &b);

    // Local: this project.
    b.runStr("file.open", "a.txt");
    b.applyWindow();
    try t.expectEqualStrings(under(&proj, &buf, "dir", ""), try sidebarShows(&b));
    // Another local project.
    b.runStr("file.open", "other/b.txt");
    b.applyWindow();
    try t.expectEqualStrings(under(&proj, &buf, "dir", "/other"), try sidebarShows(&b));

    // A file from the peer's shared tree: it opens (read-only — there is no
    // remote file backing to write through), named by its peer designation
    // and in the peer's place. So the sidebar is on the peer's tree, and the
    // file's row is highlighted there with `src` opened above it — while the
    // editor keeps the keys.
    var file_name: [128]u8 = undefined;
    const file_designation = try (durable.Designation{ .authority = .{ .peer = &fp }, .kind = .file, .ref = "/src/main.zig" }).render(&file_name);
    const opened = core.command.run(b.commands, b.ctx, "file.open", &.{.{ .string = file_designation }}) catch return error.OpenFailed;
    if (opened == .string) {
        std.debug.print("[e2e/projection] open refused: {s}\n", .{opened.string});
        return error.PeerFileRefused;
    }
    b.applyWindow();
    try t.expectEqualStrings(file_designation, b.buffers.active().designationText());
    try t.expect(b.buffers.active().read_only != null);
    {
        const text = try b.textAlloc();
        defer gpa.free(text);
        try t.expectEqualStrings("pub fn main() void {}\n", text);
    }
    try t.expectEqualStrings(tree.root_designation, core.intent.factsFor(b.ctx).get("place").?);
    try t.expectEqualStrings(tree.root_designation, try sidebarShows(&b));
    try t.expectEqualStrings(file_designation, sidebarHighlights(&b) orelse return error.NothingRevealed);
    const primary = b.win_layout.primaryPane() orelse return error.NoPrimaryPane;
    try t.expectEqual(primary, window_layout.headFocus(b.win_layout, b.head));
    proj.shot(&b, "projection-sidebar-peer");

    // The peer's place has no local directory: its problems list is
    // refused by name, never every diagnostic in the workspace standing in.
    b.run("problems.open");
    b.applyWindow();
    {
        var it = b.buffers.iterator();
        while (it.next()) |entry| {
            try t.expect(!std.mem.startsWith(u8, entry.designationText(), "weft://here/diagnostics/"));
        }
    }
    try t.expectEqualStrings(file_designation, b.buffers.active().designationText());

    // The places projection lists every place worked in — both local
    // projects and the peer's tree — as rows that open it.
    try t.expect(openOk(&b, "weft://here/places/all"));
    const view = b.toolView() orelse return error.NoPlacesView;
    const instance = b.session.system.semantic.views.get(view) orelse return error.StaleView;
    var seen_local = false;
    var seen_other = false;
    var seen_peer = false;
    for (instance.scene.content.container.children) |rownode| {
        for (rownode.facts) |f| {
            if (!std.mem.eql(u8, f.name, "designation")) continue;
            seen_local = seen_local or std.mem.eql(u8, f.value, under(&proj, &buf, "dir", ""));
            seen_other = seen_other or std.mem.eql(u8, f.value, under(&proj, &buf, "dir", "/other"));
            seen_peer = seen_peer or std.mem.eql(u8, f.value, tree.root_designation);
        }
    }
    try t.expect(seen_local and seen_other and seen_peer);
}

/// Whether the places view `view` lists `designation` as a row.
fn placesList(ed: *Editor, view: semantic_model.view.Ref, designation: []const u8) bool {
    const instance = ed.session.system.semantic.views.get(view) orelse return false;
    for (instance.scene.content.container.children) |rownode| {
        for (rownode.facts) |f| {
            if (std.mem.eql(u8, f.name, "designation") and std.mem.eql(u8, f.value, designation)) return true;
        }
    }
    return false;
}

test "e2e/projection: the places list shows a peer's tree the frame it is shared, and a place opened behind it, with the primary place unmoved" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    try makeProjects(gpa);
    try core.file.writeBytesMakingDirs(gpa, "shared/src", "shared/src/main.zig", "pub fn main() void {}\n");
    var buf: [4096]u8 = undefined;

    var a: Editor = undefined;
    try Editor.initNamed(gpa, &a, "alice");
    defer a.deinit();
    var b: Editor = undefined;
    try Editor.initNamed(gpa, &b, "bob");
    defer b.deinit();
    var loader: ConfigLoader = .{ .ed = &b };
    defer loader.deinit();
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);
    try h.bootConfigNamed(&b, config_dir, "ide.js", &loader);
    try b.buffers.setDefaultMode(gpa, b.head.currentMode());
    try b.enableCollabCommands();

    var link: h.Loopback = undefined;
    try h.Loopback.init(&link, gpa, &a, &b, "alice", "bob");
    defer link.deinit();
    const fp = link.peer_sess.peerFingerprint() orelse return error.NoHandshake;

    b.runStr("file.open", "a.txt");
    b.applyWindow();
    try t.expect(openOk(&b, "weft://here/places/all"));
    const view = b.toolView() orelse return error.NoPlacesView;
    try t.expect(placesList(&b, view, under(&proj, &buf, "dir", "")));
    const place_before = b.ctx.context.?.fingerprint("place");

    // A peer shares its tree: nothing the editor looks at moved, and the
    // list shows it.
    const shared_root = try std.fmt.allocPrint(gpa, "{s}/shared", .{proj.root});
    defer gpa.free(shared_root);
    var tree: PeerTree = undefined;
    try tree.init(gpa, &b, shared_root, &fp);
    defer tree.deinit(gpa, &b);
    b.applyWindow();
    try t.expectEqual(place_before, b.ctx.context.?.fingerprint("place"));
    try t.expect(placesList(&b, view, tree.root_designation));

    // An entry opens in another place in a companion viewport: the primary
    // place stays, and the list gains the row.
    const viewports = &b.session.system.viewports;
    try viewports.declare(gpa, "pinned", .{ .dock = .bottom, .persistent = true, .cycles = false, .focus_source = false }, .{ .rows = 4 });
    var other_buf: [4096]u8 = undefined;
    try viewports.present(gpa, "pinned", .{ .subject = .{ .text = under(&proj, &other_buf, "file", "/other/b.txt") } });
    b.applyWindow();
    b.applyWindow();
    try t.expectEqual(place_before, b.ctx.context.?.fingerprint("place"));
    try t.expect(placesList(&b, view, under(&proj, &buf, "dir", "/other")));
}

pub fn openOk(ed: *Editor, spec: []const u8) bool {
    const outcome = core.command.run(ed.commands, ed.ctx, "file.open", &.{.{ .string = spec }}) catch return false;
    ed.applyWindow();
    return outcome != .string;
}

/// The name field of the row for `name` in the listing `view` shows.
fn nameNode(ed: *Editor, view: semantic_model.view.Ref, name: []const u8) !semantic_model.scene.NodeId {
    const instance = ed.session.system.semantic.views.get(view) orelse return error.StaleView;
    for (instance.scene.content.container.children) |row| {
        for (row.content.container.children) |node| {
            if (!std.mem.eql(u8, node.role, "files.name") or node.content != .field) continue;
            var snap = try ed.session.system.semantic.fields.get(node.content.field.ref).?.snapshot(ed.gpa);
            defer snap.deinit();
            if (std.mem.eql(u8, snap.value.bytes, name)) return node.id;
        }
    }
    return error.FilesNameNotFound;
}

/// The sidebar entry's selection, wherever it rests: the head's while the
/// sidebar has the keys, else the entry's own.
fn sidebarSelection(ed: *Editor) !*core.Head.SceneSelection {
    const entry = try paneEntry(ed, try sidebarPane(ed));
    return if (entry.id == ed.buffers.active_id) &ed.head.scene_selection else &entry.scene_selection;
}

test "e2e/projection: a reveal highlights beside the selection — the rows you marked stay marked, the primary stays put" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try makeProjects(gpa);
    for ([_][]const u8{ "b.txt", "c.txt" }) |name| try core.file.writeBytes(gpa, name, "x\n");
    var buf: [4096]u8 = undefined;

    ed.runStr("file.open", "a.txt");
    ed.applyWindow();
    ed.run("window.focus-left");
    ed.applyWindow();
    const view = ed.toolView() orelse return error.NoFilesView;
    // Mark b.txt and c.txt: two extents, neither of them the editor's file.
    ed.click(ed.pointAtNode(try nameNode(ed, view, "b.txt")) orelse return error.RowNotDrawn);
    ed.applyWindow();
    ed.clickWith(ed.pointAtNode(try nameNode(ed, view, "c.txt")) orelse return error.RowNotDrawn, 1, .{ .ctrl = true });
    ed.applyWindow();
    const before = try sidebarSelection(ed);
    try t.expectEqual(@as(usize, 2), before.extentCount());
    const primary = before.primaryRows().?;
    const marked = before.others.items[0];

    // The editor moves to another file: the sidebar reveals it…
    ed.runStr("file.open", "sub/inner.txt");
    ed.applyWindow();
    try t.expectEqualStrings(under(&app.proj, &buf, "file", "/sub/inner.txt"), sidebarHighlights(ed) orelse return error.NothingRevealed);
    // …and the selection is exactly what the user made: the same primary,
    // the same marked row, nothing added.
    const after = try sidebarSelection(ed);
    try t.expectEqual(@as(usize, 2), after.extentCount());
    try t.expectEqual(primary, after.primaryRows().?);
    try t.expectEqual(marked, after.others.items[0]);
}

/// The view the sidebar's entry shows, and its published revision.
fn sidebarView(ed: *Editor) !struct { ref: semantic_model.view.Ref, revision: u64 } {
    const entry = try paneEntry(ed, try sidebarPane(ed));
    const shown = if (entry.id == ed.buffers.active_id) ed.head.scene_selection.view else entry.scene_selection.view;
    const ref = shown orelse entry.tool_view orelse return error.NoSidebarView;
    const instance = ed.session.system.semantic.views.get(ref) orelse return error.StaleView;
    return .{ .ref = ref, .revision = instance.descriptor.revision };
}

test "e2e/projection: a deep reveal opens its folders in one publish, off the layout pass — and folds them when it moves on" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try makeProjects(gpa);
    try core.file.writeBytesMakingDirs(gpa, "deep/one/two", "deep/one/two/leaf.txt", "LEAF\n");
    var buf: [4096]u8 = undefined;

    ed.runStr("file.open", "a.txt");
    ed.applyWindow();
    const before = try sidebarView(ed);

    // Three folders to open on the way: read at the frame boundary, not in
    // the layout pass that asked, and published once — still in this wake.
    ed.runStr("file.open", "deep/one/two/leaf.txt");
    ed.applyWindow();
    try t.expectEqualStrings(under(&app.proj, &buf, "file", "/deep/one/two/leaf.txt"), sidebarHighlights(ed) orelse return error.NothingRevealed);
    const deep = try sidebarView(ed);
    try t.expect(deep.ref.eql(before.ref));
    try t.expectEqual(before.revision + 1, deep.revision);
    {
        const text = try ed.semanticText(deep.ref);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "leaf.txt") != null);
    }

    // Back to a file at the top: the folders the reveal opened fold again,
    // so the listing does not keep every folder the editor ever visited.
    ed.runStr("file.open", "a.txt");
    ed.applyWindow();
    try t.expectEqualStrings(under(&app.proj, &buf, "file", "/a.txt"), sidebarHighlights(ed) orelse return error.NothingRevealed);
    {
        const text = try ed.semanticText(deep.ref);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "leaf.txt") == null);
        try t.expect(std.mem.indexOf(u8, text, "two") == null);
    }
}
