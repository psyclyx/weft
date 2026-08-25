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
        try lang.authorAndCheckSyntax(&app.proj, &app.ed, c);
    }
}

test "e2e/languages: lsp activation and capability routing are hermetic for every spine language" {
    const gpa = t.allocator;
    const command = try lang.fakeServerCommand(gpa);
    defer gpa.free(command);
    for (lang.cases) |c| {
        var app: h.App = undefined;
        try app.init(gpa);
        defer app.deinit();
        try lang.assertLsp(&app.proj, &app.ed, c, command);
    }
}
