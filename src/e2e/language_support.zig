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
    const at: *h.app.providers.Attach = @ptrCast(@alignCast(buf.frontend orelse return null));
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

/// A hermetic language-server peer. The real wasm lsp plugin starts it through
/// the proc membrane; only the peer implementation is a test double, activation
/// and Caps routing are production paths. `tag` names this peer in its marker
/// files, its pid file and the completion item it answers with, so two peers
/// running at once are told apart by what they say rather than by hope.
pub const Peer = struct {
    tag: []const u8,
    command: []u8,

    pub fn init(gpa: std.mem.Allocator, tag: []const u8) !Peer {
        return build(gpa, tag, "my $where = \"\";");
    }

    /// A peer whose completion item NAMES the directory it is running in.
    ///
    /// The two-language gate tells its servers apart by tag, because a
    /// different language means a different configured command. Two servers of
    /// the SAME language in two projects share every part of their identity
    /// except the place — so the only honest way to prove which one answered is
    /// to make each say where it is. `resolveSpawnAt` puts the child in its
    /// place's directory, so `getcwd` here IS the project the session serves.
    pub fn initRooted(gpa: std.mem.Allocator, tag: []const u8) !Peer {
        return build(gpa, tag, "my $where = Cwd::getcwd(); $where =~ s{^.*/}{}; $where = \"_$where\";");
    }

    fn build(gpa: std.mem.Allocator, tag: []const u8, where_init: []const u8) !Peer {
        // JSON::PP and Cwd are part of Perl's core distribution, not a language
        // server or project tool. The peer parses Content-Length framing and
        // answers the request's actual id, so a test cannot accidentally pass by
        // consuming a response emitted before the request that needs it.
        const script =
            \\$|=1;
            \\open(my $pid, ">", ".lsp-$tag-pid") or die;
            \\print $pid $$;
            \\close $pid;
            \\open(my $mark, ">>", ".lsp-$tag-started") or die;
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
            \\    my $method = $msg->{method} // "";
            \\    if ($method eq "textDocument/didOpen") { open(my $od, ">>", ".lsp-$tag-didopen") or die; print $od ($msg->{params}{textDocument}{uri} // "null"), "\n"; close $od; }
            \\    next unless defined $msg->{id};
            \\    if ($method eq "initialize") { open(my $init, ">>", ".lsp-$tag-init") or die; print $init ($msg->{params}{rootUri} // "null"), "\n"; close $init; }
            \\    if ($method eq "textDocument/completion") { open(my $comp, ">>", ".lsp-$tag-completion") or die; print $comp "x"; close $comp; }
            \\    my $result = {};
            \\    if ($method eq "initialize") {
            \\        $result = { capabilities => { completionProvider => {} } };
            \\    } elsif ($method eq "textDocument/completion") {
            \\        my $item = "hermetic_${tag}${where}_completion";
            \\        $result = { items => [{ label => $item, insertText => $item }] };
            \\    }
            \\    my $reply = encode_json({ jsonrpc => "2.0", id => $msg->{id}, result => $result });
            \\    print "Content-Length: ", length($reply), "\r\n\r\n", $reply;
            \\}
        ;
        // Only the tag and the `$where` preamble are interpolated by Zig; the
        // script is verbatim perl, single-quoted so the shell expands none of
        // its `$` variables.
        return .{
            .tag = tag,
            .command = try std.fmt.allocPrint(
                gpa,
                "perl -MJSON::PP -MCwd -e 'my $tag = \"{s}\";{s}{s}'",
                .{ tag, where_init, script },
            ),
        };
    }

    pub fn deinit(self: Peer, gpa: std.mem.Allocator) void {
        gpa.free(self.command);
    }

    /// This peer's `<leaf>` marker path (`started`, `init`, `didopen`,
    /// `completion`, `pid`).
    pub fn marker(self: Peer, buf: []u8, leaf: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, ".lsp-{s}-{s}", .{ self.tag, leaf }) catch unreachable;
    }

    /// The completion item only THIS peer ever answers with.
    pub fn item(self: Peer, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "hermetic_{s}_completion", .{self.tag}) catch unreachable;
    }

    /// What an `initRooted` peer answers with while running in `dir` — the
    /// identity of the SERVER INSTANCE, not merely of the configured command.
    pub fn itemIn(self: Peer, buf: []u8, dir: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "hermetic_{s}_{s}_completion", .{ self.tag, dir }) catch unreachable;
    }
};

pub fn hasResultItem(ed: *h.Editor, id: u64, text: []const u8) bool {
    const session = ed.caps.session(id) orelse return false;
    for (session.results.items) |result| {
        if (std.mem.indexOf(u8, result.provider, "lsp") == null) continue;
        if (result.payload != .completion) continue;
        for (result.payload.completion) |candidate| {
            if (std.mem.eql(u8, candidate.text, text)) return true;
        }
    }
    return false;
}

/// Fire completion at the ACTIVE buffer and wait for `peer`'s own item, proving
/// the answer came from the session serving this buffer's language.
pub fn awaitPeerCompletion(ed: *h.Editor, peer: Peer) !void {
    var buf: [64]u8 = undefined;
    return awaitCompletionItem(ed, peer.item(&buf));
}

/// Fire completion at the ACTIVE buffer and wait for one exact item — the
/// general form, so a gate can name the server INSTANCE it expects
/// (`Peer.itemIn`) rather than only the configured command (`Peer.item`).
pub fn awaitCompletionItem(ed: *h.Editor, want: []const u8) !void {
    const editor = ed.buffers.active().textEditor().?;
    const path = editor.backingPath() orelse "";
    const id = (try ed.caps.fire(.completion, &editor.doc, path, .{})) orelse
        return error.NoLspCapabilityProvider;
    defer ed.caps.finish(id);
    const deadline = h.core.task.nowNs() + 5 * std.time.ns_per_s;
    while (h.core.task.nowNs() < deadline) {
        ed.settle(4);
        if (hasResultItem(ed, id, want)) return;
    }
    return error.HermeticLspDidNotAnswer;
}

pub fn assertLsp(proj: *h.Project, ed: *h.Editor, c: Case, peer: Peer) !void {
    const dot = std.mem.lastIndexOfScalar(u8, c.path, '.') orelse unreachable;
    try ed.setConfig("lsp", c.path[dot + 1 ..], peer.command);
    var mbuf: [64]u8 = undefined;
    var cmd: [256]u8 = undefined;
    const truncated = try proj.oracle(try std.fmt.bufPrint(&cmd, ": > {s}", .{peer.marker(&mbuf, "completion")}));
    proj.gpa.free(truncated);
    // An authoring step may have left this language's file already focused, and
    // a re-open of the focused entry is not an activation. Pass through an
    // unserved buffer first, so opening the target is a real focus change. A
    // session is keyed by the command it was spawned for, so the open then
    // mints one for the hermetic peer rather than reusing whatever served this
    // language before the config above.
    ed.runStr("open", ".lsp-activation-switch.txt");
    ed.settle(2);
    ed.runStr("open", c.path);
    var saw_lsp = false;
    for (ed.caps.providers.items) |provider| {
        if (std.mem.eql(u8, provider.capability, "edit/completion") and
            std.mem.indexOf(u8, provider.id, "lsp") != null) saw_lsp = true;
    }
    try std.testing.expect(saw_lsp);
    try std.testing.expect(h.drainUntilOracle(proj, ed, try std.fmt.bufPrint(&cmd, "test -s {s} && echo yes", .{peer.marker(&mbuf, "started")}), "yes"));
    try std.testing.expect(h.drainUntilOracle(proj, ed, try std.fmt.bufPrint(&cmd, "test -s {s} && echo yes", .{peer.marker(&mbuf, "init")}), "yes"));
    ed.settle(100);
    try awaitPeerCompletion(ed, peer);
    try std.testing.expect(h.drainUntilOracle(proj, ed, try std.fmt.bufPrint(&cmd, "test -s {s} && echo yes", .{peer.marker(&mbuf, "completion")}), "yes"));
}
