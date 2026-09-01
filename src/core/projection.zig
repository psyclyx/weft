//! `projection` — a node tree rendered into a text buffer, with the HOST
//! owning every offset.
//!
//! This is the primitive `doc/plugin-api.md` §F1 is about. A plugin that shows
//! an external authority — a repository, a directory, a debugger, a test run —
//! wants a tree of rows with identity and affordances. What the API gave it was
//! a text buffer and a byte offset, so each such plugin wrote the same ~400
//! lines: emit text while tracking its own output cursor, record a
//! `[start,end)` per node into a parallel table, publish styles by offset,
//! publish folds by offset, linear-scan that table to hit-test the cursor back
//! to a row, find where a node MOVED so the cursor could be restored after a
//! re-render, and persist which rows were collapsed across a refresh.
//!
//! None of that is about git, or files, or the debugger. It is here once.
//!
//! WHAT A PLUGIN SAYS: a flat list of nodes, each with a parent ordinal, a KEY
//! it chose (a path, an OID, a section name), a ROLE, and its text. What it
//! never says, and never sees, is an offset.
//!
//! WHAT THE HOST KEEPS ACROSS A REBUILD, keyed by that key rather than by
//! position: which nodes are collapsed, and which node the cursor was on. Both
//! used to be the plugin's problem, and both were the plugin's BOUNDED problem
//! — git remembers 64 collapsed paths and drops the rest with an apology.
//!
//! IDENTITY IS NOT POSITION. A verb acts on the key the row carries, resolved
//! against the model the plugin holds. The rendered range is display and only
//! display: it hit-tests the cursor to a row and nothing else reads it. That
//! was already the rule git enforced with a file boundary and a source-scanning
//! gate; here it is enforced by the membrane, because an offset cannot cross.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// What a node contributes to the projection.
pub const Node = struct {
    /// The plugin's own identity for this row. Owned. Stable across rebuilds
    /// is the whole contract: fold state and cursor restoration are keyed by
    /// it, so a row that keeps its key keeps both.
    key: []u8,
    /// A name for what this row IS — `git.file`, `fs.directory`, `dap.frame`.
    /// Owned. Styling resolves through it (`styleFor`), and it is the hook a
    /// third party attaches to without knowing the producer.
    role: []u8,
    /// The row text, verbatim, including any indentation the producer wants.
    /// Owned. A node with empty text is a pure container: it occupies no rows
    /// of its own and folds its children.
    text: []u8,
    /// Ordinal of the enclosing node, or null at the root. A child is rendered
    /// after its parent and inside its parent's range.
    parent: ?u32 = null,
    /// Whether this node's children may be hidden.
    foldable: bool = false,

    // ── Filled by `render`; display and only display ──────────────────
    /// The node's whole rendered extent, children included.
    start: usize = 0,
    end: usize = 0,
    /// Where a fold of this node begins: past its own first line, so the header
    /// stays visible and the body collapses under it.
    body: usize = 0,

    fn deinit(self: *Node, gpa: Allocator) void {
        gpa.free(self.key);
        gpa.free(self.role);
        gpa.free(self.text);
    }
};

/// One plugin's projection over one buffer.
pub const View = struct {
    gpa: Allocator,
    /// The committed tree. Replaced wholesale on each commit.
    nodes: std.ArrayList(Node) = .empty,
    /// The tree being built, if a build is open. Kept apart from `nodes` so a
    /// build that never commits — a plugin that returned early, or trapped —
    /// leaves the live projection alone.
    building: std.ArrayList(Node) = .empty,
    open: bool = false,
    /// Collapsed keys, owned. Survives a rebuild: this is the state git
    /// remembered in a fixed `[64][256]u8` and dropped past 64 with an echo.
    collapsed: std.StringHashMapUnmanaged(void) = .empty,
    /// The key the cursor was on when the last render started. Owned.
    focus: []u8 = &.{},
    /// Bumped on every commit. A decision made against an older one is stale —
    /// the same discipline the offers table already carries.
    revision: u32 = 0,
    /// The rendered text of the last commit, owned. Kept so `render` can be
    /// asked what it produced without going back to the document.
    text: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) View {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *View) void {
        for (self.nodes.items) |*n| n.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
        for (self.building.items) |*n| n.deinit(self.gpa);
        self.building.deinit(self.gpa);
        var it = self.collapsed.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.collapsed.deinit(self.gpa);
        self.gpa.free(self.focus);
        self.text.deinit(self.gpa);
        self.* = undefined;
    }

    /// Start a new tree. An unfinished previous build is discarded — a builder
    /// that never committed said nothing.
    pub fn begin(self: *View) void {
        for (self.building.items) |*n| n.deinit(self.gpa);
        self.building.clearRetainingCapacity();
        self.open = true;
    }

    /// Add a node to the open build. Returns its ordinal, which is what a later
    /// node names as its parent.
    pub fn add(self: *View, node: struct {
        key: []const u8,
        role: []const u8,
        text: []const u8,
        parent: ?u32,
        foldable: bool,
    }) !u32 {
        if (!self.open) return error.NoBuild;
        // A parent must already exist, so the tree cannot describe a cycle or
        // a forward reference — the ordering the renderer relies on, checked
        // rather than assumed.
        if (node.parent) |p| {
            if (p >= self.building.items.len) return error.BadParent;
        }
        const key = try self.gpa.dupe(u8, node.key);
        errdefer self.gpa.free(key);
        const role = try self.gpa.dupe(u8, node.role);
        errdefer self.gpa.free(role);
        const text = try self.gpa.dupe(u8, node.text);
        errdefer self.gpa.free(text);
        try self.building.append(self.gpa, .{
            .key = key,
            .role = role,
            .text = text,
            .parent = node.parent,
            .foldable = node.foldable,
        });
        return @intCast(self.building.items.len - 1);
    }

    /// Swap the built tree in and render it. Returns the text; the caller
    /// writes it to the document and publishes the style and fold layers.
    pub fn commit(self: *View) ![]const u8 {
        if (!self.open) return error.NoBuild;
        self.open = false;
        for (self.nodes.items) |*n| n.deinit(self.gpa);
        self.nodes.clearRetainingCapacity();
        std.mem.swap(std.ArrayList(Node), &self.nodes, &self.building);
        self.revision +%= 1;
        return self.render();
    }

    /// Lay the tree out. A node contributes its own text, then its children's,
    /// so its range encloses theirs — which is what makes "the innermost node
    /// containing this offset" the right hit-test and what makes a fold of the
    /// parent hide the whole subtree.
    ///
    /// A COLLAPSED node still renders its children (they are laid out and
    /// keyed), and the fold layer hides them. That is deliberate: a fold is a
    /// view state, so folding must not change what the model says is there —
    /// which is the bug the alternative has, where a draft made under a
    /// collapsed directory vanishes with the fold.
    pub fn render(self: *View) ![]const u8 {
        self.text.clearRetainingCapacity();
        // Children follow their parent contiguously, so one pass in ordinal
        // order lays the tree out only if producers emit depth-first. They do
        // (a builder walks its own model), and a producer that does not still
        // gets correct ENCLOSURE below, because a parent's end is widened to
        // cover every descendant.
        for (self.nodes.items) |*n| {
            n.start = self.text.items.len;
            if (n.text.len > 0) {
                try self.text.appendSlice(self.gpa, n.text);
                if (n.text[n.text.len - 1] != '\n') try self.text.append(self.gpa, '\n');
            }
            n.body = self.text.items.len;
            n.end = self.text.items.len;
        }
        // Widen every node to enclose its descendants, deepest first. Walking
        // backwards works because a parent's ordinal is always lower than its
        // children's (`add` refuses a forward parent reference).
        var i = self.nodes.items.len;
        while (i > 0) {
            i -= 1;
            const n = &self.nodes.items[i];
            if (n.parent) |p| {
                const parent = &self.nodes.items[p];
                parent.end = @max(parent.end, n.end);
                parent.start = @min(parent.start, n.start);
            }
        }
        return self.text.items;
    }

    /// The innermost node covering `offset`, or null. Innermost wins because a
    /// parent encloses its children: a hunk row is inside its file's range, and
    /// the hunk is what the cursor is on.
    pub fn nodeAt(self: *const View, offset: usize) ?*const Node {
        var best: ?*const Node = null;
        for (self.nodes.items) |*n| {
            if (offset < n.start or offset >= n.end) continue;
            // Deeper means a strictly smaller range, so the tightest fit is the
            // innermost node without needing a depth to compare.
            if (best) |b| {
                if (n.end - n.start < b.end - b.start) best = n;
            } else best = n;
        }
        return best;
    }

    pub fn byKey(self: *const View, key: []const u8) ?*const Node {
        for (self.nodes.items) |*n| {
            if (std.mem.eql(u8, n.key, key)) return n;
        }
        return null;
    }

    pub fn isCollapsed(self: *const View, key: []const u8) bool {
        return self.collapsed.contains(key);
    }

    /// Flip a key's fold. Unbounded, unlike the fixed table this replaces: the
    /// set is exactly the keys you folded.
    pub fn toggleFold(self: *View, key: []const u8) !void {
        if (self.collapsed.fetchRemove(key)) |removed| {
            self.gpa.free(removed.key);
            return;
        }
        const owned = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned);
        try self.collapsed.put(self.gpa, owned, {});
    }

    /// Remember the key under `offset` so the next render can land there.
    pub fn rememberFocus(self: *View, offset: usize) void {
        const n = self.nodeAt(offset) orelse return;
        const owned = self.gpa.dupe(u8, n.key) catch return;
        self.gpa.free(self.focus);
        self.focus = owned;
    }

    /// Where the cursor should land after a render: the remembered key's row if
    /// the model still names it, else the first row. Never an offset carried
    /// over from the previous text, which is the failure this replaces — a
    /// stale offset lands on whatever row now covers it.
    pub fn focusOffset(self: *const View) usize {
        if (self.focus.len > 0) {
            if (self.byKey(self.focus)) |n| return n.start;
        }
        return if (self.nodes.items.len == 0) 0 else self.nodes.items[0].start;
    }

    /// The body lines of `key` that `[sel_start, sel_end)` covers, as ordinals
    /// relative to the node's own first body line. This is the LAST place a
    /// rendered range is read on a selection's behalf; past here a partial
    /// selection is named by ordinals, which the revision governs.
    pub fn selectedLines(self: *const View, key: []const u8, sel_start: usize, sel_end: usize) ?struct { lo: usize, hi: usize } {
        const n = self.byKey(key) orelse return null;
        const text = self.text.items;
        var ord: usize = 0;
        var lo: usize = 0;
        var hi: usize = 0;
        var seen = false;
        var i = n.start;
        while (i < n.end and i < text.len) : (ord += 1) {
            var line_end = i;
            while (line_end < n.end and line_end < text.len and text[line_end] != '\n') line_end += 1;
            if (sel_start < line_end and sel_end > i) {
                if (!seen) {
                    lo = ord;
                    seen = true;
                }
                hi = ord + 1;
            }
            i = line_end + 1;
        }
        return if (seen) .{ .lo = lo, .hi = hi } else null;
    }
};

/// The role → style mapping. A producer names WHAT a row is; how that looks is
/// resolved here, so a theme has something to theme and a plugin stops choosing
/// colours. Matching is on the last dotted segment, so `git.file` and
/// `fs.file` both read as `file` without either producer coordinating.
///
/// An unknown role is `.normal`. That is the honest default: a producer naming
/// something this table has never heard of should render as plain text, not as
/// a guess.
pub fn styleFor(role: []const u8) u8 {
    const leaf = if (std.mem.lastIndexOfScalar(u8, role, '.')) |dot| role[dot + 1 ..] else role;
    const table = .{
        .{ "added", 1 },
        .{ "removed", 2 },
        .{ "header", 3 },
        .{ "section", 3 },
        .{ "title", 3 },
        .{ "location", 4 },
        .{ "path", 4 },
        .{ "file", 4 },
        .{ "commit", 4 },
        .{ "emphasis", 5 },
        .{ "muted", 6 },
        .{ "detail", 6 },
        .{ "hunk", 6 },
    };
    inline for (table) |row| {
        if (std.mem.eql(u8, leaf, row[0])) return row[1];
    }
    return 0;
}

const t = std.testing;

test "projection: a parent encloses its children, and the innermost wins" {
    var v: View = .init(t.allocator);
    defer v.deinit();
    v.begin();
    const sec = try v.add(.{ .key = "unstaged", .role = "git.section", .text = "Unstaged", .parent = null, .foldable = true });
    const f = try v.add(.{ .key = "unstaged:a.zig", .role = "git.file", .text = "  a.zig", .parent = sec, .foldable = true });
    _ = try v.add(.{ .key = "unstaged:a.zig#0", .role = "git.hunk", .text = "@@ -1 +1 @@", .parent = f, .foldable = false });
    const text = try v.commit();
    try t.expectEqualStrings("Unstaged\n  a.zig\n@@ -1 +1 @@\n", text);

    // The hunk's own row hit-tests to the hunk, not to the file that encloses
    // it — the property every verb's targeting depends on.
    try t.expectEqualStrings("unstaged:a.zig#0", v.nodeAt(text.len - 2).?.key);
    try t.expectEqualStrings("unstaged:a.zig", v.nodeAt(9).?.key);
    try t.expectEqualStrings("unstaged", v.nodeAt(0).?.key);
    // …and the section's range covers all of it.
    try t.expectEqual(@as(usize, 0), v.byKey("unstaged").?.start);
    try t.expectEqual(text.len, v.byKey("unstaged").?.end);
}

test "projection: fold state and focus survive a rebuild, keyed not positioned" {
    var v: View = .init(t.allocator);
    defer v.deinit();
    v.begin();
    _ = try v.add(.{ .key = "a", .role = "git.file", .text = "a", .parent = null, .foldable = true });
    _ = try v.add(.{ .key = "b", .role = "git.file", .text = "b", .parent = null, .foldable = true });
    _ = try v.commit();
    try v.toggleFold("b");
    v.rememberFocus(v.byKey("b").?.start);

    // Rebuild with a row INSERTED ABOVE — the case a positional memory gets
    // wrong, because every offset below it shifted.
    v.begin();
    _ = try v.add(.{ .key = "new", .role = "git.file", .text = "new", .parent = null, .foldable = true });
    _ = try v.add(.{ .key = "a", .role = "git.file", .text = "a", .parent = null, .foldable = true });
    _ = try v.add(.{ .key = "b", .role = "git.file", .text = "b", .parent = null, .foldable = true });
    _ = try v.commit();
    try t.expect(v.isCollapsed("b"));
    try t.expect(!v.isCollapsed("a"));
    try t.expectEqual(v.byKey("b").?.start, v.focusOffset());

    // A row the model no longer names takes the cursor home rather than to
    // whatever now sits at its old offset.
    v.begin();
    _ = try v.add(.{ .key = "a", .role = "git.file", .text = "a", .parent = null, .foldable = true });
    _ = try v.commit();
    try t.expectEqual(v.byKey("a").?.start, v.focusOffset());
}

test "projection: a selection inside a node is line ordinals, never offsets" {
    var v: View = .init(t.allocator);
    defer v.deinit();
    v.begin();
    const f = try v.add(.{ .key = "f", .role = "git.file", .text = "file", .parent = null, .foldable = true });
    _ = try v.add(.{ .key = "h", .role = "git.hunk", .text = "@@\n+one\n+two\n+three", .parent = f, .foldable = false });
    const text = try v.commit();
    const h = v.byKey("h").?;
    // Cover the second and third body lines of the hunk.
    const one = h.start + 3; // inside "+one"
    const two_end = std.mem.indexOfPos(u8, text, one, "two").? + 3;
    const sel = v.selectedLines("h", one, two_end).?;
    try t.expectEqual(@as(usize, 1), sel.lo);
    try t.expectEqual(@as(usize, 3), sel.hi);
}

test "projection: styling resolves through the role's last segment" {
    // Two producers, no coordination, same reading — and an unknown role is
    // plain rather than a guess.
    try t.expectEqual(styleFor("git.file"), styleFor("fs.file"));
    try t.expectEqual(@as(u8, 1), styleFor("git.diff.added"));
    try t.expectEqual(@as(u8, 0), styleFor("something.nobody.declared"));
}
