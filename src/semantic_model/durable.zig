//! Durable, text-serializable designations — the `weft://` grammar
//! (doc/substrate.md §7, architecture §6.3, doc/model.md §2.1) and the embed
//! line built on it (§11.8, doc/cwa-config-decisions.md stress-test 2).
//!
//! `target.Ref` is a live handle: a slot and a generation, meaningless in a
//! later session. A `Designation` is the durable half — `weft://<authority>/
//! <kind>/<ref>` plus optional `?key=value&…` view parameters — and it is
//! the only way content is named across the ABI: what `open` and `present`
//! take, what a jumplist remembers, what a viewport presents, what a document
//! stores when it points at something.
//!
//! The kinds come in honest tiers (doc/model.md §2.1): stored content (`file`,
//! `dir`), documents (`doc`, a minted id), projections (one synthetic kind per
//! producer, re-run on open), and live resources (`proc`, which survive only
//! as long as their process). A position is not a kind: it is a locator in
//! the view parameters (`?at=`).
//!
//! A path kind's ref is an ABSOLUTE path, and the grammar makes that the only
//! thing it can be: the slash that separates the kind from the ref is the
//! path's own root, so `weft://here/file/home/me/a.zig` is `/home/me/a.zig`
//! and there is no spelling of a relative one (substrate §7, R1).
//!
//! Text is the storage form AND the fallback form, so nothing here allocates
//! or owns: a `Designation` borrows the bytes it was parsed from, which lets
//! a wasm guest read one straight out of a note's rope window and lets the
//! host read the same bytes back.

const std = @import("std");

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

/// What a designation designates. The four named kinds are the grammar's own
/// and mean the same thing to every reader; a `projection` kind belongs to the
/// producer that registered it (`git.status`, `grep`, `offers`) and means
/// whatever that producer re-runs to answer it.
pub const Kind = union(enum) {
    /// A stored file, by absolute path at its authority.
    file,
    /// A stored directory, by absolute path at its authority. Spelled `dir`.
    directory,
    /// A document by its minted id (`DocId`): scratch and shared text, which
    /// has no path to be named by.
    doc,
    /// A live resource — a REPL, a terminal, a console. Honest about its
    /// tier: it designates something only while the process lives.
    proc,
    /// A producer's synthetic kind. Opening one re-runs the producer.
    projection: []const u8,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .file => file_kind,
            .directory => directory_kind,
            .doc => doc_kind,
            .proc => proc_kind,
            .projection => |n| n,
        };
    }

    pub fn eql(self: Kind, other: Kind) bool {
        return switch (self) {
            .projection => |n| other == .projection and std.mem.eql(u8, n, other.projection),
            else => std.meta.activeTag(self) == std.meta.activeTag(other),
        };
    }

    /// A kind whose ref is an absolute path.
    pub fn isPath(self: Kind) bool {
        return self == .file or self == .directory;
    }

    /// The kind `text` spells, or null when it spells none. The named kinds
    /// are reserved: no producer can register a projection called `file`.
    pub fn of(text: []const u8) ?Kind {
        if (text.len == 0) return null;
        for (text) |c| if (!validKindByte(c)) return null;
        if (std.mem.eql(u8, text, file_kind)) return .file;
        if (std.mem.eql(u8, text, directory_kind)) return .directory;
        if (std.mem.eql(u8, text, doc_kind)) return .doc;
        if (std.mem.eql(u8, text, proc_kind)) return .proc;
        return .{ .projection = text };
    }

    /// Whether `text` may name a PROJECTION kind: a well-formed kind that is
    /// none of the grammar's own.
    pub fn isProjectionName(text: []const u8) bool {
        const k = of(text) orelse return false;
        return k == .projection;
    }
};

/// A kind name is a lowercase dotted word (`git.status`), so it can never
/// swallow the separator or the query and never reads as a path.
fn validKindByte(c: u8) bool {
    return std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '.' or c == '-' or c == '_';
}

/// The kind names the grammar spells. `directory` is `dir` on the wire
/// because that is what a person types.
pub const file_kind = "file";
pub const directory_kind = "dir";
pub const doc_kind = "doc";
pub const proc_kind = "proc";

/// A document's minted identity (doc/model.md §2.1): 128 random bits given at
/// creation, carried in a share announcement, and never derived from content
/// — two empty files are two documents. Minting needs the OS, so it lives
/// with whoever creates documents; this is only the value and its spelling.
pub const DocId = struct {
    bytes: [16]u8,

    /// The spelled length: 32 lowercase hex digits, no separators.
    pub const text_len = 32;

    pub fn eql(self: DocId, other: DocId) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn text(self: DocId) [text_len]u8 {
        return std.fmt.bytesToHex(self.bytes, .lower);
    }

    /// Read a spelled id. Exactly 32 lowercase hex digits, so one id has
    /// exactly one spelling and a designation compares by its bytes.
    pub fn parse(spelled: []const u8) ?DocId {
        if (spelled.len != text_len) return null;
        for (spelled) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return null;
        var id: DocId = .{ .bytes = undefined };
        _ = std.fmt.hexToBytes(&id.bytes, spelled) catch return null;
        return id;
    }
};

/// One durable designation. `params` is the raw query string; read it with
/// `param`, which is the only interpretation this module performs.
pub const Designation = struct {
    authority: Authority = .here,
    kind: Kind,
    /// For a path kind, the absolute path (it starts with `/`); for `doc`, a
    /// spelled `DocId`; otherwise the producer's or process's own name.
    ref: []const u8,
    params: []const u8 = "",

    /// The view parameter a position rides in: a byte offset into the
    /// designated text, which a live reader rebases through an anchor.
    pub const at_param = "at";

    /// A designation naming the local path `path`, or null when `path` is not
    /// absolute — the one place a path becomes a designation, and it cannot
    /// be handed a relative one.
    pub fn ofPath(kind: Kind, path: []const u8) ?Designation {
        std.debug.assert(kind.isPath());
        if (!std.fs.path.isAbsolutePosix(path)) return null;
        if (std.mem.indexOfAny(u8, path, "?\n") != null) return null;
        return .{ .kind = kind, .ref = path };
    }

    /// A designation naming document `id`. `spelled` is the caller's storage
    /// for the id's text, which the designation borrows.
    pub fn ofDoc(authority: Authority, spelled: *const [DocId.text_len]u8) Designation {
        return .{ .authority = authority, .kind = .doc, .ref = spelled };
    }

    /// The document id a `doc` designation names.
    pub fn docId(self: Designation) ?DocId {
        if (self.kind != .doc) return null;
        return DocId.parse(self.ref);
    }

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

    /// The position locator (`?at=`), or null.
    pub fn at(self: Designation) ?usize {
        const raw = self.param(at_param) orelse return null;
        return std.fmt.parseUnsigned(usize, raw, 10) catch null;
    }

    /// The same designated thing, whatever each holder asked to see of it:
    /// identity is authority/kind/ref, and view parameters are a request
    /// about presentation that never changes what is designated.
    pub fn designates(self: Designation, other: Designation) bool {
        return self.authority.eql(other.authority) and
            self.kind.eql(other.kind) and
            std.mem.eql(u8, self.ref, other.ref);
    }

    /// Whether `other` asks for the same VIEW of the same thing: it
    /// `designates` it, and its view parameters are the same set — except the
    /// position (`at`), which says where in a view, never which view. Two
    /// queries of one projection (`grep/p?q=foo`, `grep/p?q=bar`) are two
    /// views; a file and the file at line 9 are one. The one comparison
    /// everything that finds a live entry by what it shows makes.
    pub fn sameView(self: Designation, other: Designation) bool {
        if (!self.designates(other)) return false;
        return self.viewParamsIn(other) and other.viewParamsIn(self);
    }

    /// Every view parameter of `self` but `at` is in `other`, with its value.
    fn viewParamsIn(self: Designation, other: Designation) bool {
        var it = std.mem.splitScalar(u8, self.params, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const name = pair[0..eq];
            if (std.mem.eql(u8, name, at_param)) continue;
            const value = if (eq < pair.len) pair[eq + 1 ..] else "";
            const theirs = other.param(name) orelse return false;
            if (!std.mem.eql(u8, theirs, value)) return false;
        }
        return true;
    }

    /// This designation without view parameter `name`; the rest are written
    /// into `out`, which the result borrows.
    pub fn without(self: Designation, name: []const u8, out: []u8) error{NoSpaceLeft}!Designation {
        var d = self;
        var len: usize = 0;
        var it = std.mem.splitScalar(u8, self.params, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            if (std.mem.eql(u8, pair[0..eq], name)) continue;
            const sep: usize = @intFromBool(len != 0);
            if (len + sep + pair.len > out.len) return error.NoSpaceLeft;
            if (sep != 0) out[len] = '&';
            @memcpy(out[len + sep ..][0..pair.len], pair);
            len += sep + pair.len;
        }
        d.params = out[0..len];
        return d;
    }

    /// The same designation without its view parameters.
    pub fn bare(self: Designation) Designation {
        var d = self;
        d.params = "";
        return d;
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
        // A path kind's ref brings its own root slash, which doubles as the
        // separator; every other ref needs one.
        const sep: []const u8 = if (self.kind.isPath()) "" else "/";
        const query: []const u8 = if (self.params.len == 0) "" else "?";
        return std.fmt.bufPrint(out, scheme ++ "{s}{s}/{s}{s}{s}{s}{s}", .{
            prefix,
            auth,
            self.kind.name(),
            sep,
            self.ref,
            query,
            self.params,
        });
    }

    /// `render` into a fresh allocation. Caller owns the result.
    pub fn renderAlloc(self: Designation, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
        var buf: [4096]u8 = undefined;
        const text = self.render(&buf) catch {
            // Longer than any path this editor opens; spell it the slow way.
            var list: std.ArrayList(u8) = .empty;
            errdefer list.deinit(gpa);
            try list.appendSlice(gpa, scheme);
            try list.appendSlice(gpa, switch (self.authority) {
                .here => "here",
                .peer => |name| name,
                .shell => "shell:",
            });
            if (self.authority == .shell) try list.appendSlice(gpa, self.authority.shell);
            try list.append(gpa, '/');
            try list.appendSlice(gpa, self.kind.name());
            if (!self.kind.isPath()) try list.append(gpa, '/');
            try list.appendSlice(gpa, self.ref);
            if (self.params.len != 0) {
                try list.append(gpa, '?');
                try list.appendSlice(gpa, self.params);
            }
            return list.toOwnedSlice(gpa);
        };
        return gpa.dupe(u8, text);
    }

    /// How a person reads this designation: a local path with `$HOME` shown
    /// as `~`, a peer's path under the peer's name, a document or process by
    /// kind and short id. Display only — `home` abbreviates and nothing here
    /// is parsed back. `peer_name` is the display name for a peer authority
    /// (null shows the authority as written).
    pub fn display(self: Designation, out: []u8, home: []const u8, peer_name: ?[]const u8) std.fmt.BufPrintError![]const u8 {
        const where: []const u8 = switch (self.authority) {
            .here => "",
            .peer => |name| peer_name orelse name,
            .shell => |id| id,
        };
        const colon: []const u8 = if (where.len == 0) "" else ":";
        return switch (self.kind) {
            .file, .directory => {
                const path = if (self.authority == .here) abbreviateHome(self.ref, home) else .{ "", self.ref };
                return std.fmt.bufPrint(out, "{s}{s}{s}{s}", .{ where, colon, path[0], path[1] });
            },
            .doc => std.fmt.bufPrint(out, "{s}{s}doc {s}", .{ where, colon, self.ref[0..@min(self.ref.len, 8)] }),
            .proc => std.fmt.bufPrint(out, "{s}{s}proc {s}", .{ where, colon, self.ref }),
            .projection => |k| std.fmt.bufPrint(out, "{s}{s}{s} {s}", .{ where, colon, k, self.ref }),
        };
    }
};

/// `path` as `~` plus a remainder when it is `home` or below it, else as is.
/// Answered as a (prefix, rest) pair so nothing is copied.
fn abbreviateHome(path: []const u8, home: []const u8) struct { []const u8, []const u8 } {
    if (home.len <= 1 or !std.mem.startsWith(u8, path, home)) return .{ "", path };
    const rest = path[home.len..];
    if (rest.len == 0) return .{ "~", "" };
    if (rest[0] != '/') return .{ "", path };
    return .{ "~", rest };
}

/// Parse one designation. Borrows `text`; null when it is not a `weft://`
/// value, names no kind, or its ref is not one that kind can hold.
pub fn parse(text: []const u8) ?Designation {
    if (!std.mem.startsWith(u8, text, scheme)) return null;
    const body = text[scheme.len..];
    const auth_end = std.mem.indexOfScalar(u8, body, '/') orelse return null;
    const authority = parseAuthority(body[0..auth_end]) orelse return null;
    const rest = body[auth_end + 1 ..];
    const kind_end = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const kind = Kind.of(rest[0..kind_end]) orelse return null;
    // A path kind keeps the separator as its root; every other kind's ref
    // starts after it.
    const tail = if (kind.isPath()) rest[kind_end..] else rest[kind_end + 1 ..];
    const query = std.mem.indexOfScalar(u8, tail, '?');
    const ref = if (query) |q| tail[0..q] else tail;
    if (!validRef(kind, ref)) return null;
    return .{
        .authority = authority,
        .kind = kind,
        .ref = ref,
        .params = if (query) |q| tail[q + 1 ..] else "",
    };
}

fn validRef(kind: Kind, ref: []const u8) bool {
    if (std.mem.indexOfScalar(u8, ref, '\n') != null) return false;
    return switch (kind) {
        // `/` alone is the root directory, and no file.
        .directory => !std.mem.startsWith(u8, ref, "//"),
        .file => ref.len > 1 and !std.mem.startsWith(u8, ref, "//") and ref[ref.len - 1] != '/',
        .doc => DocId.parse(ref) != null,
        .proc, .projection => ref.len != 0,
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

/// What a string handed to `open` or `present` names: a designation, or a
/// bare absolute path standing in for `weft://here/file|dir/<path>` (which of
/// the two only the filesystem can say). A relative path names nothing — it
/// would have to be resolved against the process directory, which is exactly
/// the ambient answer the designation exists to replace — so it is refused,
/// never guessed at.
pub const Spec = union(enum) {
    designation: Designation,
    path: []const u8,
    relative,
    malformed,

    pub fn of(text: []const u8) Spec {
        if (std.mem.startsWith(u8, text, scheme))
            return if (parse(text)) |d| .{ .designation = d } else .malformed;
        if (std.fs.path.isAbsolutePosix(text)) return .{ .path = text };
        return .relative;
    }

    /// The message a refusal shows, naming what was given.
    pub const relative_refusal = "a relative path names nothing: give an absolute path or a weft:// designation";
    pub const malformed_refusal = "not a designation: weft://<authority>/<kind>/<ref>";
};

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

test "a designation of every kind round-trips through its text form" {
    var buf: [160]u8 = undefined;
    const cases = [_][]const u8{
        "weft://here/file/src/core/Head.zig",
        "weft://here/dir/src?lines=5",
        "weft://here/dir/",
        "weft://here/file/notes.md?at=1024&lines=3",
        "weft://here/commit/deadbeefcafe",
        "weft://deadbeef/dir/src",
        "weft://shell:build-box/file/main.c",
        "weft://here/doc/000102030405060708090a0b0c0d0e0f",
        "weft://alice/doc/ffeeddccbbaa99887766554433221100?at=7",
        "weft://here/proc/repl.3",
        "weft://here/git.status/home/me/weft",
        "weft://here/offers/primary",
        "weft://here/grep/home/me/weft?q=TODO",
    };
    for (cases) |text| {
        const d = parse(text) orelse {
            std.debug.print("did not parse: {s}\n", .{text});
            return error.TestUnexpectedResult;
        };
        try t.expectEqualStrings(text, try d.render(&buf));
        const owned = try d.renderAlloc(t.allocator);
        defer t.allocator.free(owned);
        try t.expectEqualStrings(text, owned);
    }
}

test "each kind reads as itself, and a path kind's ref is absolute by construction" {
    try t.expect(parse("weft://here/file/a.zig").?.kind == .file);
    try t.expectEqualStrings("/a.zig", parse("weft://here/file/a.zig").?.ref);
    try t.expect(parse("weft://here/dir/").?.kind == .directory);
    try t.expectEqualStrings("/", parse("weft://here/dir/").?.ref);
    try t.expect(parse("weft://here/proc/terminal.1").?.kind == .proc);
    const doc = parse("weft://here/doc/000102030405060708090a0b0c0d0e0f").?;
    try t.expect(doc.kind == .doc);
    try t.expectEqual(@as(u8, 0x0f), doc.docId().?.bytes[15]);
    const projection = parse("weft://here/git.status/r").?;
    try t.expectEqualStrings("git.status", projection.kind.projection);
    try t.expect(!projection.kind.isPath());
    // A kind name cannot be spelled like a path or a query.
    try t.expect(Kind.of("Git") == null);
    try t.expect(Kind.of("a?b") == null);
    try t.expect(Kind.isProjectionName("make"));
    try t.expect(!Kind.isProjectionName("file"));
    try t.expect(!Kind.isProjectionName("doc"));
}

test "a document id has exactly one spelling" {
    var id: DocId = .{ .bytes = undefined };
    for (&id.bytes, 0..) |*b, i| b.* = @intCast(i * 17);
    const spelled = id.text();
    try t.expect(DocId.parse(&spelled).?.eql(id));
    try t.expect(DocId.parse("000102030405060708090A0B0C0D0E0F") == null); // upper case
    try t.expect(DocId.parse("0001") == null);
    try t.expect(parse("weft://here/doc/xyz") == null);
    try t.expect(parse("weft://here/doc/000102030405060708090a0b0c0d0e0f00") == null);
    const d = Designation.ofDoc(.here, &spelled);
    try t.expect(d.docId().?.eql(id));
}

test "authority and view parameters are read, not guessed" {
    const d = parse("weft://here/dir/src?lines=5&label=source").?;
    try t.expect(d.authority == .here);
    try t.expect(d.kind == .directory);
    try t.expectEqualStrings("/src", d.ref);
    try t.expectEqualStrings("5", d.param("lines").?);
    try t.expectEqualStrings("source", d.param("label").?);
    try t.expect(d.param("sparkline") == null);
    try t.expectEqual(@as(usize, 5), d.count("lines", 2));
    try t.expectEqual(@as(usize, 2), d.count("cols", 2));
    try t.expectEqual(@as(?usize, 12), parse("weft://here/file/a?at=12").?.at());
    try t.expectEqual(@as(?usize, null), d.at());

    // View parameters are a request about presentation, never identity.
    try t.expect(d.designates(parse("weft://here/dir/src?lines=99").?));
    try t.expect(!d.designates(parse("weft://here/file/src").?));
    try t.expect(!d.designates(parse("weft://alice/dir/src").?));
    try t.expect(parse("weft://here/commit/abc").?.designates(parse("weft://here/commit/abc").?));
    try t.expect(!parse("weft://here/commit/abc").?.designates(parse("weft://here/tag/abc").?));
    try t.expectEqualStrings("", d.bare().params);

    // A view is the designated thing plus every parameter but the position.
    try t.expect(d.sameView(parse("weft://here/dir/src?label=source&lines=5&at=3").?));
    try t.expect(!d.sameView(parse("weft://here/dir/src?lines=5").?));
    try t.expect(!d.sameView(parse("weft://here/dir/src?lines=6&label=source").?));
    const grep = parse("weft://here/grep/p?q=foo&at=4").?;
    try t.expect(!grep.sameView(parse("weft://here/grep/p?q=bar").?));
    try t.expect(parse("weft://here/file/a").?.sameView(parse("weft://here/file/a?at=9").?));
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("q=foo", (try grep.without("at", &buf)).params);
    try t.expectEqualStrings("lines=5", (try d.without("label", &buf)).params);

    const peer = parse("weft://alice/file/a.zig").?;
    try t.expect(peer.authority.eql(.{ .peer = "alice" }));
    const shell = parse("weft://shell:box/file/a.c").?;
    try t.expect(shell.authority.eql(.{ .shell = "box" }));
}

test "a malformed designation is not a designation" {
    try t.expect(parse("https://example.com/x") == null);
    try t.expect(parse("weft://here") == null);
    try t.expect(parse("weft://here/file/") == null);
    try t.expect(parse("weft://here/file//x") == null);
    try t.expect(parse("weft://here/file/x/") == null);
    try t.expect(parse("weft:///file/x") == null);
    try t.expect(parse("weft://here//x") == null);
    try t.expect(parse("weft://shell:/file/x") == null);
    try t.expect(parse("weft://here/proc/") == null);
    try t.expect(parse("weft://here/git.status/") == null);
}

test "a path is sugar only when it is absolute" {
    try t.expect(Spec.of("/home/me/a.zig") == .path);
    try t.expect(Spec.of("a.zig") == .relative);
    try t.expect(Spec.of(".") == .relative);
    try t.expect(Spec.of("../x") == .relative);
    try t.expect(Spec.of("weft://here/doc/nope") == .malformed);
    try t.expect(Spec.of("weft://here/dir/tmp") == .designation);
    try t.expect(Designation.ofPath(.file, "rel/a.zig") == null);
    const d = Designation.ofPath(.directory, "/tmp").?;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("weft://here/dir/tmp", try d.render(&buf));
}

test "the display form is absolute, abbreviates home, and names a peer" {
    var buf: [128]u8 = undefined;
    const home = "/home/me";
    try t.expectEqualStrings("~/src/a.zig", try parse("weft://here/file/home/me/src/a.zig").?.display(&buf, home, null));
    try t.expectEqualStrings("~", try parse("weft://here/dir/home/me").?.display(&buf, home, null));
    try t.expectEqualStrings("/home/meadow", try parse("weft://here/dir/home/meadow").?.display(&buf, home, null));
    try t.expectEqualStrings("/tmp/x", try parse("weft://here/dir/tmp/x").?.display(&buf, home, null));
    try t.expectEqualStrings("alice:/src", try parse("weft://abcd/dir/src").?.display(&buf, home, "alice"));
    try t.expectEqualStrings("abcd:/home/me", try parse("weft://abcd/dir/home/me").?.display(&buf, home, null));
    try t.expectEqualStrings("doc 00010203", try parse("weft://here/doc/000102030405060708090a0b0c0d0e0f").?.display(&buf, home, null));
}

test "an embed line is a marker plus one designation, and nothing else" {
    var buf: [128]u8 = undefined;
    const embed = embedOf("  @embed weft://here/dir/src?lines=2").?;
    try t.expect(embed.kind == .directory);
    try t.expectEqualStrings("/src", embed.ref);
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
