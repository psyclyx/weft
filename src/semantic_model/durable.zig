//! Durable, text-serializable designations — the `weft://` grammar
//! (doc/substrate.md §7, architecture §6.3) and the embed line built on it
//! (§11.8, doc/cwa-config-decisions.md stress-test 2).
//!
//! `target.Ref` is a live handle: a slot and a generation, meaningless in a
//! later session. A `Designation` is the durable half — `weft://<authority>/
//! <kind>/<ref>` plus optional `?key=value&…` view parameters — and it is
//! what a document stores when it points at something.
//!
//! Text is the storage form AND the fallback form, so nothing here allocates
//! or owns: a `Designation` borrows the bytes it was parsed from, which lets
//! a wasm guest read one straight out of a note's rope window and lets the
//! host read the same bytes back.

const std = @import("std");
const target = @import("target.zig");

/// Where the referenced thing lives (substrate §7: a path without its locus
/// means nothing). `here` is this process; the rest carry the authority
/// verbatim, because a fingerprint, an alias, and a shell id are all just
/// names to everyone but the locus registry that resolves them.
pub const Authority = union(enum) {
    here,
    peer: []const u8,
    shell: []const u8,

    pub fn eql(self: Authority, other: Authority) bool {
        return switch (self) {
            .here => other == .here,
            .peer => |name| other == .peer and std.mem.eql(u8, name, other.peer),
            .shell => |id| other == .shell and std.mem.eql(u8, id, other.shell),
        };
    }
};

pub const scheme = "weft://";

/// The kind names the grammar spells. `directory` is `dir` on the wire
/// because that is what a person types; every other kind is its own name and
/// round-trips as `synthetic`.
pub const file_kind = "file";
pub const directory_kind = "dir";

/// One durable designation. `params` is the raw query string; read it with
/// `param`, which is the only interpretation this module performs.
pub const Designation = struct {
    authority: Authority = .here,
    kind: target.Kind,
    ref: []const u8,
    params: []const u8 = "",

    /// The value of view parameter `name`, or null. Parameters are advisory
    /// by construction — an unknown one is ignored, never an error, so an
    /// older reader degrades to the plain designation instead of refusing.
    pub fn param(self: Designation, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.params, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        }
        return null;
    }

    /// `param` read as an unsigned count, or `fallback` when absent or
    /// unparseable.
    pub fn count(self: Designation, name: []const u8, fallback: usize) usize {
        const raw = self.param(name) orelse return fallback;
        return std.fmt.parseUnsigned(usize, raw, 10) catch fallback;
    }

    /// The same designated thing, whatever each holder asked to see of it:
    /// identity is authority/kind/ref, and view parameters are a request
    /// about presentation that never changes what is designated.
    pub fn designates(self: Designation, other: Designation) bool {
        return self.authority.eql(other.authority) and
            kindEql(self.kind, other.kind) and
            std.mem.eql(u8, self.ref, other.ref);
    }

    /// Write the designation back out. Serializing then parsing yields an
    /// equal value — that round trip is what makes the text form the
    /// fallback form.
    pub fn render(self: Designation, out: []u8) std.fmt.BufPrintError![]const u8 {
        const auth: []const u8 = switch (self.authority) {
            .here => "here",
            .peer => |name| name,
            .shell => |id| id,
        };
        const prefix: []const u8 = if (self.authority == .shell) "shell:" else "";
        const query: []const u8 = if (self.params.len == 0) "" else "?";
        return std.fmt.bufPrint(out, scheme ++ "{s}{s}/{s}/{s}{s}{s}", .{
            prefix,
            auth,
            kindName(self.kind),
            self.ref,
            query,
            self.params,
        });
    }
};

/// The grammar's name for a kind. `unknown` has no durable spelling: a
/// designation that cannot say what it points at is not durable.
pub fn kindName(kind: target.Kind) []const u8 {
    return switch (kind) {
        .unknown => "",
        .file => file_kind,
        .directory => directory_kind,
        .synthetic => |name| name,
    };
}

fn kindEql(self: target.Kind, other: target.Kind) bool {
    return switch (self) {
        .synthetic => |name| other == .synthetic and std.mem.eql(u8, name, other.synthetic),
        else => std.meta.activeTag(self) == std.meta.activeTag(other),
    };
}

fn kindOf(name: []const u8) ?target.Kind {
    if (name.len == 0) return null;
    if (std.mem.eql(u8, name, file_kind)) return .file;
    if (std.mem.eql(u8, name, directory_kind)) return .directory;
    return .{ .synthetic = name };
}

/// Parse one designation. Borrows `text`; null when it is not a `weft://`
/// value or names no kind and ref.
pub fn parse(text: []const u8) ?Designation {
    if (!std.mem.startsWith(u8, text, scheme)) return null;
    const body = text[scheme.len..];
    const auth_end = std.mem.indexOfScalar(u8, body, '/') orelse return null;
    const authority = parseAuthority(body[0..auth_end]) orelse return null;
    const rest = body[auth_end + 1 ..];
    const kind_end = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const kind = kindOf(rest[0..kind_end]) orelse return null;
    const tail = rest[kind_end + 1 ..];
    const query = std.mem.indexOfScalar(u8, tail, '?');
    const ref = if (query) |at| tail[0..at] else tail;
    if (ref.len == 0) return null;
    return .{
        .authority = authority,
        .kind = kind,
        .ref = ref,
        .params = if (query) |at| tail[at + 1 ..] else "",
    };
}

fn parseAuthority(text: []const u8) ?Authority {
    if (text.len == 0) return null;
    if (std.mem.eql(u8, text, "here")) return .here;
    if (std.mem.startsWith(u8, text, "shell:")) {
        const id = text["shell:".len..];
        return if (id.len == 0) null else .{ .shell = id };
    }
    return .{ .peer = text };
}

// ── The embed line (§11.8) ──────────────────────────────────────────
//
// An embed is a text span holding a durable designation plus view params.
// A whole line is the span, and a bare word marks it, so an embed is
// greppable, survives any editor, and reads as itself when nothing resolves
// it. Everything outside the marker is the designation grammar above —
// there is no second syntax to keep in step.

pub const marker = "@embed";

/// How much of the designated thing to show. One spelling for every kind —
/// a directory's entries and a file's lines are the same request, and a
/// reader that had to guess which word this resource wants would be reading
/// two grammars.
pub const window_param = "lines";

/// The designation on `line` if it is an embed line, else null. Leading
/// whitespace is allowed (an embed indents inside a list); trailing text
/// after the designation is not, so a sentence mentioning an embed is prose.
pub fn embedOf(line: []const u8) ?Designation {
    const body = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, body, marker)) return null;
    const rest = std.mem.trimStart(u8, body[marker.len..], " \t");
    if (rest.len == body.len - marker.len) return null; // marker needs a separator
    if (std.mem.indexOfAny(u8, rest, " \t") != null) return null;
    return parse(rest);
}

/// Write an embed line (no trailing newline) for `designation`.
pub fn renderEmbed(designation: Designation, out: []u8) std.fmt.BufPrintError![]const u8 {
    if (out.len < marker.len + 1) return error.NoSpaceLeft;
    @memcpy(out[0..marker.len], marker);
    out[marker.len] = ' ';
    const body = try designation.render(out[marker.len + 1 ..]);
    return out[0 .. marker.len + 1 + body.len];
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "a designation round-trips through its text form" {
    var buf: [128]u8 = undefined;
    const cases = [_][]const u8{
        "weft://here/file/src/core/Head.zig",
        "weft://here/dir/src?lines=5",
        "weft://here/file/notes.md?at=1024&lines=3",
        "weft://here/commit/deadbeefcafe",
        "weft://deadbeef/dir/src",
        "weft://shell:build-box/file/main.c",
    };
    for (cases) |text| {
        const d = parse(text) orelse return error.TestUnexpectedResult;
        try t.expectEqualStrings(text, try d.render(&buf));
    }
}

test "authority and view parameters are read, not guessed" {
    const d = parse("weft://here/dir/src?lines=5&label=source").?;
    try t.expect(d.authority == .here);
    try t.expect(d.kind == .directory);
    try t.expectEqualStrings("src", d.ref);
    try t.expectEqualStrings("5", d.param("lines").?);
    try t.expectEqualStrings("source", d.param("label").?);
    try t.expect(d.param("sparkline") == null);
    try t.expectEqual(@as(usize, 5), d.count("lines", 2));
    try t.expectEqual(@as(usize, 2), d.count("cols", 2));

    // View parameters are a request about presentation, never identity.
    try t.expect(d.designates(parse("weft://here/dir/src?lines=99").?));
    try t.expect(!d.designates(parse("weft://here/file/src").?));
    try t.expect(!d.designates(parse("weft://alice/dir/src").?));
    try t.expect(parse("weft://here/commit/abc").?.designates(parse("weft://here/commit/abc").?));
    try t.expect(!parse("weft://here/commit/abc").?.designates(parse("weft://here/tag/abc").?));

    const peer = parse("weft://alice/file/a.zig").?;
    try t.expect(peer.authority.eql(.{ .peer = "alice" }));
    const shell = parse("weft://shell:box/file/a.c").?;
    try t.expect(shell.authority.eql(.{ .shell = "box" }));
}

test "a malformed designation is not a designation" {
    try t.expect(parse("https://example.com/x") == null);
    try t.expect(parse("weft://here") == null);
    try t.expect(parse("weft://here/file/") == null);
    try t.expect(parse("weft:///file/x") == null);
    try t.expect(parse("weft://here//x") == null);
    try t.expect(parse("weft://shell:/file/x") == null);
}

test "an embed line is a marker plus one designation, and nothing else" {
    var buf: [128]u8 = undefined;
    const embed = embedOf("  @embed weft://here/dir/src?lines=2").?;
    try t.expect(embed.kind == .directory);
    try t.expectEqualStrings("src", embed.ref);
    try t.expectEqualStrings(
        "@embed weft://here/dir/src?lines=2",
        try renderEmbed(embed, &buf),
    );

    try t.expect(embedOf("see @embed weft://here/dir/src") == null);
    try t.expect(embedOf("@embed weft://here/dir/src and more") == null);
    try t.expect(embedOf("@embedweft://here/dir/src") == null);
    try t.expect(embedOf("@embed") == null);
    try t.expect(embedOf("an ordinary note line") == null);
}
