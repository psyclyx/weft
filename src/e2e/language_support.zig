//! Data-driven language support used by the existing whole-app spine.

const std = @import("std");
const h = @import("harness.zig");

pub const Case = struct { name: []const u8, path: []const u8, source: []const u8 };
pub const cases = [_]Case{
    .{ .name = "zig", .path = "main.zig", .source = "fn main() void {}\n" },
    .{ .name = "fennel", .path = "build.fnl", .source = "(fn main [] (print \"ok\"))\n" },
    .{ .name = "lua", .path = "build.lua", .source = "local function main() return 1 end\n" },
    .{ .name = "nix", .path = "flake.nix", .source = "{ description = \"weft\"; }\n" },
    .{ .name = "javascript", .path = "app.js", .source = "function greet() { return 1; }\n" },
    .{ .name = "html", .path = "index.html", .source = "<!doctype html>\n<title>weft demo</title>\n" },
};

pub fn attachedSyntax(ed: *h.Editor) ?*h.core.syntax.Syntax {
    const buf = ed.buffers.active();
    const at: *h.app_providers.Attach = @ptrCast(@alignCast(buf.frontend orelse return null));
    return at.syntax;
}

pub fn waitForTree(ed: *h.Editor, syn: *h.core.syntax.Syntax) bool {
    const deadline = h.core.task.nowNs() + 5 * std.time.ns_per_s;
    while (h.core.task.nowNs() < deadline) {
        ed.settle(2);
        _ = syn.sync(ed.gpa, &ed.buffers.active().textEditor().?.doc) catch {};
        if (syn.tree != null) return true;
    }
    return false;
}

pub fn authorAndCheckSyntax(ed: *h.Editor, c: Case) !void {
    ed.runStr("open", c.path);
    ed.press("i", "");
    ed.typeText(c.source);
    ed.press("Escape", "");
    ed.run("save");
    ed.waitSave();
    const syn = attachedSyntax(ed) orelse return error.SyntaxDidNotAttach;
    try std.testing.expectEqualStrings(c.name, syn.spec.name);
    try std.testing.expect(waitForTree(ed, syn));
    try std.testing.expect(syn.nodeAt(0) != null);
    const painted = try syn.paint(ed.gpa, .{ .start = 0, .end = ed.buffers.active().textEditor().?.doc.text().byteLen() });
    defer ed.gpa.free(painted);
    try std.testing.expect(painted.len > 0);
}

/// The real wasm lsp plugin starts this peer through the proc membrane. Only
/// the peer implementation is a test double; activation and Caps routing are
/// production paths.
pub fn fakeServerCommand(gpa: std.mem.Allocator) ![]u8 {
    // JSON::PP is part of Perl's core distribution, not a language server or
    // project tool. The peer parses Content-Length framing and answers the
    // request's actual id, so this test cannot accidentally pass by consuming
    // a response emitted before the request that needs it.
    const script =
        \\$|=1;
        \\open(my $mark, ">>", ".lsp-started") or die;
        \\print $mark "x";
        \\close $mark;
        \\while (1) {
        \\    my $line = <STDIN>;
        \\    last unless defined $line;
        \\    my $n = 0;
        \\    while ($line ne "\r\n" && $line ne "\n") {
        \\        $n = $1 if $line =~ /Content-Length:\s*(\d+)/;
        \\        $line = <STDIN>;
        \\        last unless defined $line;
        \\    }
        \\    last if $n == 0;
        \\    my $body = "";
        \\    while (length($body) < $n) {
        \\        my $got = read(STDIN, my $part, $n - length($body));
        \\        last unless defined $got && $got > 0;
        \\        $body .= $part;
        \\    }
        \\    last unless length($body) == $n;
        \\    my $msg = decode_json($body);
        \\    next unless defined $msg->{id};
        \\    my $method = $msg->{method} // "";
        \\    if ($method eq "initialize") { open(my $init, ">>", ".lsp-init") or die; print $init "x"; close $init; }
        \\    if ($method eq "textDocument/completion") { open(my $comp, ">>", ".lsp-completion") or die; print $comp "x"; close $comp; }
        \\    my $result = {};
        \\    if ($method eq "initialize") {
        \\        $result = { capabilities => { completionProvider => {} } };
        \\    } elsif ($method eq "textDocument/completion") {
        \\        $result = { items => [{ label => "hermetic_completion", insertText => "hermetic_completion" }] };
        \\    }
        \\    my $reply = encode_json({ jsonrpc => "2.0", id => $msg->{id}, result => $result });
        \\    print "Content-Length: ", length($reply), "\r\n\r\n", $reply;
        \\}
    ;
    return std.fmt.allocPrint(gpa, "perl -MJSON::PP -e '{s}'", .{script});
}

pub fn hasHermeticResult(ed: *h.Editor, id: u64) bool {
    const session = ed.caps.session(id) orelse return false;
    for (session.results.items) |result| {
        if (std.mem.indexOf(u8, result.provider, "lsp") == null) continue;
        if (result.payload != .completion) continue;
        for (result.payload.completion) |item| {
            if (std.mem.eql(u8, item.text, "hermetic_completion")) return true;
        }
    }
    return false;
}

pub fn assertLsp(proj: *h.Project, ed: *h.Editor, c: Case, command: []const u8) !void {
    const dot = std.mem.lastIndexOfScalar(u8, c.path, '.') orelse unreachable;
    try ed.setConfig("lsp", c.path[dot + 1 ..], command);
    // A syntax authoring step may have activated this language before the
    // hermetic command was installed.  Switch through a configured sentinel
    // extension so the guest's normal language-routing path closes that old
    // session before reopening the target with this command.
    try ed.setConfig("lsp", "txt", command);
    _ = try proj.oracle(": > .lsp-started; : > .lsp-init; : > .lsp-completion");
    ed.runStr("open", ".lsp-activation-switch.txt");
    ed.settle(20);
    ed.runStr("open", c.path);
    var saw_lsp = false;
    for (ed.caps.providers.items) |provider| {
        if (std.mem.eql(u8, provider.capability, "edit/completion") and
            std.mem.indexOf(u8, provider.id, "lsp") != null) saw_lsp = true;
    }
    try std.testing.expect(saw_lsp);
    try std.testing.expect(h.drainUntilOracle(proj, ed, "test -s .lsp-started && echo yes", "yes"));
    try std.testing.expect(h.drainUntilOracle(proj, ed, "test -s .lsp-init && echo yes", "yes"));
    ed.settle(100);
    const path = ed.buffers.active().textEditor().?.backingPath() orelse c.path;
    const id = (try ed.caps.fire(.completion, &ed.buffers.active().textEditor().?.doc, path, .{})) orelse
        return error.NoLspCapabilityProvider;
    defer ed.caps.finish(id);
    try std.testing.expect(h.drainUntilOracle(proj, ed, "test -s .lsp-completion && echo yes", "yes"));
    const deadline = h.core.task.nowNs() + 5 * std.time.ns_per_s;
    while (h.core.task.nowNs() < deadline) {
        ed.settle(4);
        if (hasHermeticResult(ed, id)) {
            const clean = try proj.oracle("rm -f .lsp-started .lsp-init .lsp-completion");
            proj.gpa.free(clean);
            return;
        }
    }
    return error.HermeticLspDidNotAnswer;
}
