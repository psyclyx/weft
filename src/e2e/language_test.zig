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
