//! Hermetic language activation gates for the whole-app spine's shared catalog.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const lang = @import("language_support.zig");

test "e2e/languages: every spine language activates its pinned tree-sitter grammar" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    for (lang.cases) |c| {
        try t.expect(app.ed.prov.grammars.forPath(c.path) != null);
        try lang.authorAndCheckSyntax(&app.ed, c);
    }
}

test "e2e/languages: lsp activation and capability routing are hermetic for every spine language" {
    const gpa = t.allocator;
    const peer = try lang.Peer.init(gpa, "peer");
    defer peer.deinit(gpa);
    for (lang.cases) |c| {
        var app: h.App = undefined;
        try app.init(gpa);
        defer app.deinit();
        try lang.assertLsp(&app.proj, &app.ed, c, peer);
    }
}

test "e2e/languages: two languages are two servers — both answer, and killing one leaves the other whole" {
    const gpa = t.allocator;
    // Two peers, distinguishable by what they answer: a result carrying the
    // wrong tag would be one server answering for the other's buffer.
    const alpha = try lang.Peer.init(gpa, "alpha");
    defer alpha.deinit(gpa);
    const beta = try lang.Peer.init(gpa, "beta");
    defer beta.deinit(gpa);

    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try ed.setConfig("lsp", "zig", alpha.command);
    try ed.setConfig("lsp", "nix", beta.command);
    {
        const out = try app.proj.oracle("printf 'pub fn main() void {}\\n' > iso.zig; printf '{ description = \"iso\"; }\\n' > iso.nix");
        gpa.free(out);
    }

    // BOTH ATTACH: opening one file of each language brings up one server each,
    // neither displacing the other.
    ed.runStr("open", "iso.zig");
    ed.runStr("open", "iso.nix");
    try t.expect(h.drainUntilOracle(&app.proj, ed, "test -s .lsp-alpha-init && echo yes", "yes"));
    try t.expect(h.drainUntilOracle(&app.proj, ed, "test -s .lsp-beta-init && echo yes", "yes"));

    // BOTH ANSWER, each in its own buffer, each with its own tag.
    ed.runStr("open", "iso.zig");
    ed.settle(40);
    try lang.awaitPeerCompletion(ed, alpha);
    ed.runStr("open", "iso.nix");
    ed.settle(40);
    try lang.awaitPeerCompletion(ed, beta);

    // KILL ONE: alpha's server dies outright (its pid file is the handle; no
    // process-name matching, so nothing else in the run can be caught by it).
    {
        const out = try app.proj.oracle("kill -9 \"$(cat .lsp-alpha-pid)\" && echo killed");
        defer gpa.free(out);
        try t.expectEqualStrings("killed", out);
    }

    // THE OTHER IS WHOLE: beta still serves its buffer, through the same
    // provider registration, with no repair step in between.
    ed.runStr("open", "iso.nix");
    ed.settle(40);
    try lang.awaitPeerCompletion(ed, beta);
}

// The session table used to hold a fixed number of servers — most recently 24,
// with the coldest evicted (and a line echoed about it) when a 25th project
// wanted one. Nobody decided 24: it was the height of a static array, and the
// cost of getting it wrong is a full handshake plus a re-index against a real
// server. Sessions are individually allocated now, so this drives 26 at once.
//
// Both halves of what the pointer-list shape is FOR are asserted: past the old
// ceiling nothing is shed, and the session minted FIRST — whose `*Session`, and
// whose per-kind pending slots, were handed out before 25 more allocations —
// still answers for its own project at the end, when it is the coldest thing in
// the table and would have been the first thing evicted.
test "e2e/places: twenty-six projects, one language — every server stays up, and the first still answers last" {
    const gpa = t.allocator;
    const peer = try lang.Peer.initRooted(gpa, "zig");
    defer peer.deinit(gpa);

    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ed.setConfig("lsp", "zig", peer.command);

    // 26 marked project roots side by side. Two-digit names throughout, so the
    // directory each peer names itself by is unambiguous.
    const projects = 26;
    for (1..projects + 1) |n| {
        var cmd: [128]u8 = undefined;
        const out = try app.proj.oracle(try std.fmt.bufPrint(
            &cmd,
            "mkdir -p p{d:0>2}/.git && printf 'pub fn f() void {{}}\\n' > p{d:0>2}/main.zig",
            .{ n, n },
        ));
        gpa.free(out);
    }

    // Opening a file in each project mints its session and spawns its server.
    for (1..projects + 1) |n| {
        var path: [32]u8 = undefined;
        ed.runStr("open", try std.fmt.bufPrint(&path, "p{d:0>2}/main.zig", .{n}));
    }

    // ALL 26 HANDSHOOK. One oracle counts the markers rather than 26 — a shed
    // session leaves its marker behind, so the count is over live SPAWNS; the
    // per-project answers below are what prove each is still up.
    var want: [8]u8 = undefined;
    try t.expect(h.drainUntilOracle(
        &app.proj,
        ed,
        "ls p[0-9][0-9]/.lsp-zig-init 2>/dev/null | wc -l",
        try std.fmt.bufPrint(&want, "{d}", .{projects}),
    ));

    // EACH ANSWERS FOR ITS OWN PROJECT. The item names the directory the
    // answering server runs in, so a reply carrying another project's name is
    // one server serving two buffers.
    var item: [128]u8 = undefined;
    var dir: [8]u8 = undefined;
    for (1..projects + 1) |n| {
        var path: [32]u8 = undefined;
        ed.runStr("open", try std.fmt.bufPrint(&path, "p{d:0>2}/main.zig", .{n}));
        ed.settle(40);
        try lang.awaitCompletionItem(ed, peer.itemIn(&item, try std.fmt.bufPrint(&dir, "p{d:0>2}", .{n})));
    }

    // AND THE FIRST ONE STILL DOES, LAST. It is now the least recently used
    // session in the table — precisely what the old shedding rule retired to
    // make room, and what a moved-out-from-under `*Session` would have lost.
    ed.runStr("open", "p01/main.zig");
    ed.settle(40);
    try lang.awaitCompletionItem(ed, peer.itemIn(&item, "p01"));
}

// A workspace root is as long as the user's directories are. The session key
// held it in a `[512]u8`, and `activeKey` correctly refused to build a key it
// could not hold whole — but the consequence was that LSP did NOTHING for such
// a project, with no echo and nothing to tell it apart from "no server
// configured for this language". A capability that silently declines is the
// worst answer available: the user debugs their config instead of their paths.
test "e2e/places: a project root past the old 512-byte key limit starts a server like any other" {
    const gpa = t.allocator;
    const peer = try lang.Peer.initRooted(gpa, "zig");
    defer peer.deinit(gpa);

    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ed.setConfig("lsp", "zig", peer.command);

    // Three 200-character components: the absolute root is past 600 bytes on
    // its own, before the harness's own temporary prefix.
    const seg = "d" ** 200;
    const deep = seg ++ "/" ++ seg ++ "/" ++ seg;
    {
        var cmd: [2048]u8 = undefined;
        const out = try app.proj.oracle(try std.fmt.bufPrint(
            &cmd,
            "mkdir -p {s}/.git && printf 'pub fn deep() void {{}}\\n' > {s}/main.zig",
            .{ deep, deep },
        ));
        gpa.free(out);
    }
    {
        // The root really is past the old limit — otherwise this gate would
        // pass for the wrong reason.
        var cmd: [2048]u8 = undefined;
        const len = try app.proj.oracle(try std.fmt.bufPrint(&cmd, "cd {s} && pwd | tr -d '\\n' | wc -c", .{deep}));
        defer gpa.free(len);
        try t.expect(try std.fmt.parseInt(usize, len, 10) > 512);
    }

    var path: [1024]u8 = undefined;
    ed.runStr("open", try std.fmt.bufPrint(&path, "{s}/main.zig", .{deep}));

    // A server, started IN that project — the marker's LOCATION is the proof.
    var cmd: [2048]u8 = undefined;
    try t.expect(h.drainUntilOracle(
        &app.proj,
        ed,
        try std.fmt.bufPrint(&cmd, "test -s {s}/.lsp-zig-init && echo yes", .{deep}),
        "yes",
    ));
    {
        // And it was told the whole root, not a prefix of it: a truncated key
        // names a different workspace.
        const root_uri = try app.proj.oracle(try std.fmt.bufPrint(&cmd, "cat {s}/.lsp-zig-init", .{deep}));
        defer gpa.free(root_uri);
        try t.expect(std.mem.endsWith(u8, root_uri, deep));
    }

    // And it answers for the buffer, through the ordinary capability path. The
    // peer names itself by its own directory, which here is 200 characters.
    ed.settle(40);
    var item: [512]u8 = undefined;
    try lang.awaitCompletionItem(ed, peer.itemIn(&item, seg));
}

test "e2e/places: two projects, ONE language — two servers, each rooted in and answering for its own project" {
    const gpa = t.allocator;
    // The two-language gate above separates its servers by CONFIGURATION: a
    // different language means a different command, so two sessions are
    // unsurprising. Here every part of the session's identity is the same —
    // one language, one configured command — except WHERE. Before places, the
    // root in the session key was filled from the process's launch directory,
    // so it was the same for both projects and the two files shared a single
    // server; the second project's file was silently served by a language
    // server rooted in the first. That is the bug this gate exists to keep
    // dead (`doc/place.md` §7, wave 4).
    const peer = try lang.Peer.initRooted(gpa, "zig");
    defer peer.deinit(gpa);

    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ed.setConfig("lsp", "zig", peer.command);

    // Two marked project roots, side by side, BELOW the launch directory —
    // so a detector without places sees one project (the launch directory) and
    // a detector with them sees two.
    for ([_][]const u8{
        "mkdir -p proj-a/.git proj-b/.git",
        "printf 'pub fn a() void {}\\n' > proj-a/main.zig",
        "printf 'pub fn b() void {}\\n' > proj-b/main.zig",
    }) |cmd| {
        const out = try app.proj.oracle(cmd);
        gpa.free(out);
    }

    ed.runStr("open", "proj-a/main.zig");
    ed.runStr("open", "proj-b/main.zig");

    // TWO SERVERS, each started IN its own project. The peer writes its marker
    // files relative to its own working directory, and the spawn door puts a
    // child in the dispatching place — so the marker LOCATION is the proof,
    // needing no cooperation from the peer beyond writing a relative path.
    try t.expect(h.drainUntilOracle(&app.proj, ed, "test -s proj-a/.lsp-zig-init && echo yes", "yes"));
    try t.expect(h.drainUntilOracle(&app.proj, ed, "test -s proj-b/.lsp-zig-init && echo yes", "yes"));
    {
        // Neither is a stray in the launch directory: a single shared server
        // would have left its marker here instead of in either project.
        const stray = try app.proj.oracle("test -e .lsp-zig-init && echo leaked || echo clean");
        defer gpa.free(stray);
        try t.expectEqualStrings("clean", stray);
    }

    // EACH WAS TOLD ITS OWN WORKSPACE. `rootUri` was the literal null while
    // every session shared one root; the peer records what it was actually
    // handed, so this reads the wire, not the plugin's intent.
    for ([_][]const u8{ "proj-a", "proj-b" }) |project| {
        var cmd: [64]u8 = undefined;
        const root_uri = try app.proj.oracle(try std.fmt.bufPrint(&cmd, "cat {s}/.lsp-zig-init", .{project}));
        defer gpa.free(root_uri);
        try t.expect(std.mem.startsWith(u8, root_uri, "file:///"));
        var suffix: [64]u8 = undefined;
        try t.expect(std.mem.endsWith(u8, root_uri, try std.fmt.bufPrint(&suffix, "/{s}", .{project})));
    }

    // EACH ANSWERS FOR ITS OWN PROJECT. The item names the directory the
    // answering server is running in, so a reply carrying the other project's
    // name would be one server serving both buffers — the exact pre-place
    // behaviour.
    var want: [128]u8 = undefined;
    ed.runStr("open", "proj-a/main.zig");
    ed.settle(40);
    try lang.awaitCompletionItem(ed, peer.itemIn(&want, "proj-a"));
    ed.runStr("open", "proj-b/main.zig");
    ed.settle(40);
    try lang.awaitCompletionItem(ed, peer.itemIn(&want, "proj-b"));

    // AND THE DOCUMENT IT WAS OPENED WITH NAMES A FILE THAT EXISTS. The buffer
    // path here is spelled `proj-a/main.zig` — relative to the LAUNCH
    // directory — while the place is `<…>/proj-a`, so a naive join of the two
    // yields `<…>/proj-a/proj-a/main.zig`: an absolute uri for a file that was
    // never there, which a server answers about forever without complaining.
    // `weft.placePath` drops what the two spellings share; this reads the
    // result off the wire.
    for ([_][]const u8{ "proj-a", "proj-b" }) |project| {
        var cmd: [64]u8 = undefined;
        const uri = try app.proj.oracle(try std.fmt.bufPrint(&cmd, "head -1 {s}/.lsp-zig-didopen", .{project}));
        defer gpa.free(uri);
        var tail: [64]u8 = undefined;
        try t.expect(std.mem.endsWith(u8, uri, try std.fmt.bufPrint(&tail, "/{s}/main.zig", .{project})));
        var doubled: [64]u8 = undefined;
        try t.expect(std.mem.indexOf(u8, uri, try std.fmt.bufPrint(&doubled, "/{s}/{s}/", .{ project, project })) == null);
    }
}
