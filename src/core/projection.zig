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

/// A stretch WITHIN one node's own text, styled by its own role — the matched
/// substring in a search result, the path at the head of a compiler line.
///
/// The offsets are into the NODE'S TEXT, which the producer wrote, never into
/// the document. That distinction is the whole reason this can exist here: a
/// plugin naming a range of bytes it authored one call ago is naming something
/// it knows; a plugin naming a document offset is naming something that moved.
/// The host adds the node's own rendered start, so a row that shifts by a
/// thousand bytes keeps its emphasis on the same characters.
///
/// This is what lets a tool view stop calling the offset styling door at all.
/// `grep` used to paint its match with `weft.style(base + content_start + off,
/// …)` — three offsets added together, one of them recovered by re-scanning
/// the rendered line.
pub const Span = struct {
    start: u32,
    end: u32,
    /// Owned. Resolved through `theme/<leaf>` exactly as a node's role is, so the
    /// theme sees one vocabulary and a producer still chooses no colours.
    role: []u8,
};

/// The stretch of a row the user may type into. No role: it is not a styling
/// decision, it is which bytes are a FIELD.
pub const Edit = struct { start: u32, end: u32 };

/// What a node contributes to the projection.
pub const Node = struct {
    /// The plugin's own identity for this row. Owned. Stable across rebuilds
    /// is the whole contract: fold state and cursor restoration are keyed by
    /// it, so a row that keeps its key keeps both.
    key: []u8,
    /// A name for what this row IS — `git.file`, `fs.directory`, `dap.frame`.
    /// Owned. Styling resolves through it (`theme/<leaf>`), and it is the hook a
    /// third party attaches to without knowing the producer.
    role: []u8,
    /// The row text, verbatim, including any indentation the producer wants.
    /// Owned. A node with empty text is a pure container: it occupies no rows
    /// of its own and folds its children.
    text: []u8,
    /// Ordinal of the enclosing node, or null at the root. A child is rendered
    /// after its parent and inside its parent's range.
    parent: ?u32 = null,
    /// Whether this node.s children may be hidden.
    foldable: bool = false,
    /// Whether the cursor should be able to REST here. A producer emits rows
    /// that are structure (a title, a branch header) and rows that are
    /// subjects; only the second kind is somewhere a verb can act, so only the
    /// second kind is where a fresh render should land.
    focusable: bool = false,
    /// WHICH PART of this row the user may type into, or null for none.
    ///
    /// A span, not a flag, because a row is not all name: `  ▸ src` is an
    /// indent, a glyph and a name, and only the last is the user.s to change.
    /// Whole-row editing let a keystroke at the row start turn the glyph into
    /// text and silently rename the entry to something nobody typed.
    ///
    /// This is doc/plugin-api.md §F2.s fork closed from the text side. The two
    /// planes divided as "text, or identity-and-fields": a producer wanting a
    /// row the user edits in place — a rebase plan, a rename in a directory
    /// listing — had to leave the text plane and give up search, yank and
    /// selection to get it. A row is text AND has an identity here, and the
    /// part of it that is a FIELD is this span.
    editable: ?Edit = null,
    /// Styled stretches inside this node's own text. Owned.
    spans: std.ArrayList(Span) = .empty,

    /// Where this row's text BEGAN and ENDED, as anchors that shift with the
    /// user's typing. Set for an editable node after a render; null otherwise.
    /// Opaque here — the host mints and reads them, because only the host has
    /// the document they live in.
    anchor_start: ?u64 = null,
    anchor_end: ?u64 = null,

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
        for (self.spans.items) |s| gpa.free(s.role);
        self.spans.deinit(gpa);
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
    /// WHO publishes this projection. The entry owns the view; this is what
    /// keeps a second plugin from rebuilding or folding someone else.s rows.
    owner: []u8 = &.{},

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
        self.gpa.free(self.owner);
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
        focusable: bool = false,
        editable: ?Edit = null,
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
            .focusable = node.focusable,
            .editable = node.editable,
        });
        return @intCast(self.building.items.len - 1);
    }

    /// Style `[start,end)` of node `ordinal`'s own text.
    ///
    /// CLAMPED, not refused: a producer computing a span from its own text can
    /// be off by a byte at the end of a truncated row, and losing the whole
    /// row's emphasis over that is worse than shortening the span. An
    /// inverted or empty range says nothing and is dropped.
    pub fn span(self: *View, ordinal: u32, start: usize, end: usize, role: []const u8) !void {
        if (!self.open) return error.NoBuild;
        if (ordinal >= self.building.items.len) return error.BadNode;
        const n = &self.building.items[ordinal];
        const lo = @min(start, n.text.len);
        const hi = @min(end, n.text.len);
        if (lo >= hi) return;
        const owned = try self.gpa.dupe(u8, role);
        errdefer self.gpa.free(owned);
        try n.spans.append(self.gpa, .{ .start = @intCast(lo), .end = @intCast(hi), .role = owned });
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

    /// What a verb pressed at `offset` ACTS ON: the innermost node covering it,
    /// walked up to the nearest `focusable` ancestor.
    ///
    /// "The node at point" and "the subject at point" are different questions,
    /// and answering the second with the first is a real defect rather than an
    /// approximation. A diff line inside a hunk is not focusable — its producer
    /// said so — so point resting on it names the HUNK, which is exactly what a
    /// person means by pointing at a line of a change. Reading the leaf's own
    /// role instead made `s` on a context line afford nothing at all.
    ///
    /// Null when no ancestor is focusable: point is on pure structure (a
    /// section header), which affords nothing rather than affording whatever
    /// its container happens to.
    pub fn subjectAt(self: *const View, offset: usize) ?*const Node {
        var n = self.nodeAt(offset) orelse return null;
        // Bounded by the node count: a parent ordinal always refers to an
        // EARLIER node (the builder appends parents first), so this terminates,
        // and the bound holds even if a malformed tree says otherwise.
        var hops: usize = 0;
        while (!n.focusable) : (hops += 1) {
            if (hops > self.nodes.items.len) return null;
            const p = n.parent orelse return null;
            if (p >= self.nodes.items.len) return null;
            n = &self.nodes.items[p];
        }
        return n;
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
        // No remembered row: the first row a verb could act on, not merely the
        // first row. Landing on a header would leave every verb with nothing
        // under point, which reads as the projection being inert.
        for (self.nodes.items) |n| {
            if (n.focusable) return n.start;
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

/// The slot a role's appearance resolves through: `theme/<leaf>`, value-shaped,
/// first-wins. Core binds the defaults below at `.core` tier, so a config or a
/// theme plugin restyles any role by binding the same slot at a higher tier —
/// and can bind roles core never heard of, which is what makes a new producer's
/// vocabulary themeable without core learning it.
pub const theme_slot_prefix = "theme/";

/// A bound value is a STYLE CLASS NAME, not a number. Two reasons, and the
/// second is not cosmetic: `weft.bind("theme/hunk", "muted")` is what a person
/// would write, and `StyleClass` is an exhaustive enum — so a number would let
/// a config bind 42 and turn a colour lookup into illegal behaviour. A name
/// that is not a class simply is not one, and reads as `normal`.
pub const Class = @import("capability.zig").StyleClass;

/// What core says each role looks like, ABSENT any other opinion. This is data
/// bound into the container at `.core` tier (`declareTheme`), not a switch — so
/// it is overridable in the same way as everything else rather than in a way
/// peculiar to styling.
pub const default_theme = [_]struct { leaf: []const u8, class: Class }{
    .{ .leaf = "added", .class = .added },
    .{ .leaf = "removed", .class = .removed },
    .{ .leaf = "header", .class = .header },
    .{ .leaf = "section", .class = .header },
    .{ .leaf = "title", .class = .header },
    .{ .leaf = "location", .class = .location },
    .{ .leaf = "path", .class = .location },
    .{ .leaf = "file", .class = .location },
    .{ .leaf = "commit", .class = .location },
    .{ .leaf = "emphasis", .class = .emphasis },
    .{ .leaf = "muted", .class = .muted },
    .{ .leaf = "detail", .class = .muted },
    .{ .leaf = "hunk", .class = .muted },
};

/// A role's LEAF — the last dotted segment, so `git.file` and `fs.file` both
/// read as `file` without either producer coordinating with the other.
pub fn leafOf(role: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, role, '.')) |dot| role[dot + 1 ..] else role;
}

/// Declare `theme/<leaf>` and bind core's defaults. Called once from
/// `System.init`, beside `pick.declareAnnotation` and for the same reason: core
/// has to READ these answers, so it declares the shape it can interpret.
pub fn declareTheme(container: *@import("container.zig").Container) !void {
    inline for (default_theme) |row| {
        const slot = theme_slot_prefix ++ row.leaf;
        try container.declareSlot(.{ .name = slot, .shape = .value, .composition = .first_wins });
        try container.bind(.{
            .slot = slot,
            .provider = .{ .value = @tagName(row.class) },
            .predicate = .{ .all = &.{} },
            .tier = .core,
            .owner = "core.theme",
        });
    }
}

/// The role → style class for one role, resolved through the container.
///
/// An unknown role is `.normal` (0). That is the honest default: a producer
/// naming something nobody has themed should render as plain text, not as a
/// guess — and a theme that wants otherwise says so by binding the slot.
pub fn styleForIn(container: *const @import("container.zig").Container, f: @import("weft_facts").Facts, role: []const u8) Class {
    var buf: [128]u8 = undefined;
    const slot = std.fmt.bufPrint(&buf, theme_slot_prefix ++ "{s}", .{leafOf(role)}) catch return .normal;
    const winner = container.resolveOne(slot, f) orelse return .normal;
    const name = switch (winner.provider) {
        .value => |v| v,
        else => return .normal,
    };
    // A name that is not a class reads as `normal` rather than becoming one by
    // arithmetic — the enum is exhaustive, so there is no such thing as class 42
    // to fall back to.
    inline for (@typeInfo(Class).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @field(Class, field.name);
    }
    return .normal;
}

const t = std.testing;

/// A container holding only core's theme, for the tests below.
fn themedContainer() !@import("container.zig").Container {
    var c = @import("container.zig").Container.init(t.allocator);
    errdefer c.deinit();
    try declareTheme(&c);
    return c;
}

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
    var c = try themedContainer();
    defer c.deinit();
    try t.expectEqual(styleForIn(&c, .{}, "git.file"), styleForIn(&c, .{}, "fs.file"));
    try t.expectEqual(Class.added, styleForIn(&c, .{}, "git.diff.added"));
    try t.expectEqual(Class.normal, styleForIn(&c, .{}, "something.nobody.declared"));
}

test "projection: a theme rebinds a role, and can style one core never heard of" {
    // The point of `theme/<leaf>` being a slot rather than a switch: core's
    // answers are bindings at `.core` tier, so anything above outranks them by
    // the ordinary rule — no styling-specific override mechanism.
    var c = try themedContainer();
    defer c.deinit();

    // Core's defaults, read through the container rather than the table.
    try t.expectEqual(Class.added, styleForIn(&c, .{}, "git.diff.added"));
    try t.expectEqual(Class.normal, styleForIn(&c, .{}, "output.result"));

    // A theme restyles an existing role…
    try c.bind(.{
        .slot = theme_slot_prefix ++ "added",
        .provider = .{ .value = "emphasis" },
        .predicate = .{ .all = &.{} },
        .tier = .config,
        .owner = "my-theme",
    });
    try t.expectEqual(Class.emphasis, styleForIn(&c, .{}, "git.diff.added"));
    // …and every producer that named that leaf follows, without knowing.
    try t.expectEqual(Class.emphasis, styleForIn(&c, .{}, "dap.added"));

    // …and styles a role core has never heard of, which is the half a
    // hardcoded table could not do at all.
    try c.declareSlot(.{ .name = theme_slot_prefix ++ "result", .shape = .value, .composition = .first_wins });
    try c.bind(.{
        .slot = theme_slot_prefix ++ "result",
        .provider = .{ .value = "location" },
        .predicate = .{ .all = &.{} },
        .tier = .config,
        .owner = "my-theme",
    });
    try t.expectEqual(Class.location, styleForIn(&c, .{}, "output.result"));

    // A theme may be CONTEXTUAL, because eligibility is the ordinary predicate:
    // the same role reads differently in a different mode, with nothing in the
    // styling path aware that modes exist.
    try c.bind(.{
        .slot = theme_slot_prefix ++ "added",
        .provider = .{ .value = "removed" },
        .predicate = .{ .mode = "review" },
        .tier = .config,
        .owner = "my-theme",
    });
    try t.expectEqual(Class.removed, styleForIn(&c, .{ .mode = "review" }, "git.diff.added"));
    try t.expectEqual(Class.emphasis, styleForIn(&c, .{ .mode = "normal" }, "git.diff.added"));

    // A NONSENSE value is inert, and this is why the binding is a class NAME.
    // `StyleClass` is an exhaustive enum: had the value been a number, a config
    // that said 42 would have reached `@enumFromInt(42)` and turned a colour
    // lookup into illegal behaviour. There is no name that is not a class, only
    // names that are not one.
    try c.bind(.{
        .slot = theme_slot_prefix ++ "muted",
        .provider = .{ .value = "chartreuse" },
        .predicate = .{ .all = &.{} },
        .tier = .config,
        .owner = "my-theme",
    });
    try t.expectEqual(Class.normal, styleForIn(&c, .{}, "git.diff.muted"));
}
