//! The one selection model (doc/model.md §2.6, CWA §6.6): what the user has
//! selected, and how a command maps over it.
//!
//! A selection is one or more EXTENTS plus a primary and anchor/head posture.
//! An extent is a text range (an `Editor` selection: byte offsets) or a range
//! of rows in a scene (the scene entry's selection: node ids, anchor row to
//! head row in view order). A structural selection — a tree-sitter node — is
//! its byte range: nothing yet needs a node's identity to outlive an edit, so
//! it is a text extent, not a third kind.
//!
//! Every command DECLARES how it maps over the set (`Arity`), and dispatch
//! does the mapping (`map`, called by `command.run`), so no command writes a
//! per-selection loop and none can get one wrong:
//!
//!   - `.each` runs once per extent — reverse document order, inside ONE undo
//!     unit, each run seeing its extent as the one selection (a VISIT: the
//!     single-selection API reads and writes that extent alone). Registers
//!     collect one value per extent and a flash one set over all of them.
//!     With `over`, each extent is first mapped to a TARGET by a range command
//!     run on the untouched text (edits are refused meanwhile); identical
//!     targets run once, nested ones each run, partially overlapping ones
//!     refuse the command (`merge` unions them instead — lines), and the
//!     command then runs once per target with the target as its range
//!     argument, visiting the extent that produced it.
//!   - `.whole` runs once and reads the set itself (a command that shapes the
//!     set — split, add-next-match, collapse — or that never reads it).
//!   - `.homogeneous` runs once, refused when the extents differ in kind.
//!
//! An UNDECLARED command on a selection of several extents is REFUSED, with
//! the reason said. The old default — run once, see the primary through the
//! single-selection API — is exactly the bug every multi-selection review
//! finding was: an action that silently acted on one of N selections. Under
//! refusal that bug cannot be written; the worst an undeclared command does is
//! say so. One extent is the degenerate case: nothing maps, every arity runs.
//!
//! A dispatch handed an explicit range or anchor runs once whatever its arity:
//! its subject is the argument, not the selection (an operator a grammar hands
//! a motion's range). On several extents that holds only where a run CHOSE the
//! range — inside a visit, or under a command that took the set on (`.whole`,
//! `.homogeneous`); elsewhere it is one extent's range picked by nobody, and
//! refused as undeclared.

const std = @import("std");
const Allocator = std.mem.Allocator;

const command = @import("command.zig");
const Editor = @import("Editor.zig");
const Register = @import("register.zig");
const subbuffer = @import("subbuffer.zig");
const Document = @import("Document.zig");
const Buffers = @import("Buffers.zig");
const Head = @import("Head.zig");
const semantic_model = @import("weft_semantic");

/// What an extent is a range of.
pub const Kind = enum(u32) {
    /// Byte offsets in the entry's document.
    text = 0,
    /// Node ids in the entry's scene: the rows from `anchor` to `head`.
    rows = 1,
};

/// One extent as it crosses a door: its kind and its two ends. A text caret
/// is `anchor == head`; a single row is `anchor == head`.
pub const Extent = struct {
    kind: Kind = .text,
    anchor: u64,
    head: u64,
};

/// How a command maps over a selection of several extents.
pub const Arity = union(enum) {
    each: Each,
    whole,
    homogeneous,

    pub const Each = struct {
        /// A range command run per extent, on the untouched text, to find
        /// the TARGET the command then runs on (null: the extent itself).
        over: ?[]const u8 = null,
        /// Union overlapping targets rather than refusing them (lines: two
        /// selections on one line indent it once).
        merge: bool = false,
    };

    pub const each_extent: Arity = .{ .each = .{} };

    /// The wire code `declare_arity` carries (`membrane` spec). 0 each,
    /// 1 whole, 2 homogeneous, 3 each-over, 4 each-over merging.
    pub fn code(self: Arity) u32 {
        return switch (self) {
            .each => |e| if (e.over == null) 0 else if (e.merge) 4 else 3,
            .whole => 1,
            .homogeneous => 2,
        };
    }

    /// The arity a wire code names, with `over` borrowed from the caller;
    /// null for an unknown code (or an over-code with no command).
    pub fn fromCode(c: u32, over: []const u8) ?Arity {
        return switch (c) {
            0 => each_extent,
            1 => .whole,
            2 => .homogeneous,
            3, 4 => if (over.len == 0) null else .{ .each = .{ .over = over, .merge = c == 4 } },
            else => null,
        };
    }
};

/// The shape a mapping decision reads: how many extents, and whether they
/// differ in kind.
pub const Shape = struct {
    count: usize = 1,
    mixed: bool = false,
    /// Whether the extents are text. A target is found by a range command
    /// over text, so `.each` with `over` finds none among rows.
    text: bool = true,
};

pub const Refusal = error{
    /// A command that declares no mapping met several extents.
    UndeclaredMapping,
    /// A `.homogeneous` command met extents of different kinds.
    MixedExtents,
    /// An `.each` command's targets partially overlap.
    OverlappingTargets,
    /// An `.each` command that maps over TARGETS met several extents that are
    /// not text: a target is a range of text, and rows have none.
    UntargetableExtents,
};

/// `err` as a mapping refusal, or null for any other failure: the one test
/// every place that SHOWS a refusal asks, so a refusal added to the set is
/// shown everywhere at once.
pub fn asRefusal(err: anyerror) ?Refusal {
    inline for (@typeInfo(Refusal).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return @field(Refusal, e.name);
    }
    return null;
}

/// Whether a command of `arity` can run on `shape`, else why not. The ONE
/// reading dispatch refuses by and availability disables by, so an offer the
/// toolbar greys is exactly a command dispatch would refuse.
pub fn admits(arity: ?Arity, shape: Shape) ?Refusal {
    if (shape.count <= 1) return null;
    const a = arity orelse return error.UndeclaredMapping;
    return switch (a) {
        .homogeneous => if (shape.mixed) error.MixedExtents else null,
        .each => |e| if (e.over != null and !shape.text) error.UntargetableExtents else null,
        .whole => null,
    };
}

/// The reason code and sentence a refusal is SHOWN by — dispatch's echo,
/// the offers' disabled reason, explain and which-key all read these.
pub fn reason(r: Refusal) struct { code: []const u8, message: []const u8 } {
    return switch (r) {
        error.UndeclaredMapping => .{ .code = "one-selection", .message = "acts on one selection; several are selected" },
        error.MixedExtents => .{ .code = "mixed-selection", .message = "needs selections of one kind" },
        error.OverlappingTargets => .{ .code = "overlapping-targets", .message = "the selections' targets overlap" },
        error.UntargetableExtents => .{ .code = "text-selection", .message = "acts on text selections; these are rows" },
    };
}

/// The shape of the selection of the entry `ctx` is about. Inside a visit
/// there is exactly one extent, whatever the entry holds.
pub fn shapeOf(ctx: *command.Context) Shape {
    if (ctx.visit != null) return .{};
    const entry = ctx.entry() orelse return .{};
    return shapeOfEntry(entry, &ctx.head.scene_selection);
}

/// The shape of `entry`'s selection: its editor's text extents, or — for an
/// entry with no text — the rows `focus` (its scene selection) holds.
pub fn shapeOfEntry(entry: *Buffers.Buffer, focus: *const Head.SceneSelection) Shape {
    if (entry.textEditor()) |ed| return .{ .count = ed.selectionCount() };
    return .{ .count = @max(1, focus.extentCount()), .text = false };
}

// ── The visit ────────────────────────────────────────────────────────

/// The run of a mapping in flight, set on `command.Context.visit` for each
/// run. Nested dispatches see it and map nothing: inside a visit the visited
/// extent is the selection.
pub const Visit = struct {
    /// The visited extent's place in document order, and how many there are:
    /// what a register value is filed under and read back by.
    index: usize,
    count: usize,
    /// Runs still to come after this one (a guest's per-command epilogue runs
    /// on the last).
    remaining: usize,
    /// Set while targets are found: nothing may edit.
    targeting: bool = false,
    stage: *Stage,
};

/// What a mapping collects across its runs and lands once when it ends.
pub const Stage = struct {
    gpa: Allocator,
    /// The bank the yanks go to (the first stager names it — there is one per
    /// system), and per slot the value each visited extent yanked.
    bank: ?*Register.Bank = null,
    yanks: [Register.Bank.slot_count]std.ArrayList(Piece) = @splat(.empty),
    /// What the runs flashed, anchored so later runs' edits carry it, and the
    /// document it is in: landed as ONE flash, in document order.
    flash_doc: ?*Document = null,
    flashes: std.ArrayList(Document.RangeAnchors) = .empty,

    pub const Piece = struct { index: usize, value: Register };

    pub fn init(gpa: Allocator) Stage {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Stage) void {
        for (&self.yanks) |*list| {
            for (list.items) |*piece| piece.value.deinit(self.gpa);
            list.deinit(self.gpa);
        }
        self.flashes.deinit(self.gpa);
    }

    /// A run flashed `r` in `doc`.
    pub fn flash(self: *Stage, doc: *Document, r: Document.Range) Allocator.Error!void {
        if (self.flash_doc) |d| if (d != doc) return;
        self.flash_doc = doc;
        try self.flashes.ensureUnusedCapacity(self.gpa, 1);
        self.flashes.appendAssumeCapacity(try doc.addRangeAnchors(self.gpa, r));
    }

    /// Land the flash (every run's ranges, one set, document order) through
    /// `ctx`'s flash service, and let go of the anchors. `alive` says the
    /// document is still open; a closed one took its anchors with it.
    fn landFlash(self: *Stage, ctx: *command.Context, alive: bool) void {
        const doc = self.flash_doc orelse return;
        defer self.flashes.clearRetainingCapacity();
        if (!alive) return;
        const ranges = self.gpa.alloc(Document.Range, self.flashes.items.len) catch return;
        defer self.gpa.free(ranges);
        for (self.flashes.items, ranges) |a, *r| {
            r.* = doc.rangeOffsets(a.start, a.end);
            doc.removeAnchor(a.start);
            doc.removeAnchor(a.end);
        }
        std.mem.sort(Document.Range, ranges, {}, struct {
            fn lt(_: void, a: Document.Range, b: Document.Range) bool {
                return a.start < b.start;
            }
        }.lt);
        for (ranges, 0..) |r, i| {
            const fr: @import("flash.zig").Range = .{ .start = @intCast(r.start), .end = @intCast(r.end) };
            if (i == 0) {
                ctx.caps.flash.set(self.gpa, &ctx.caps.layers, doc, fr, .edit) catch return;
            } else ctx.caps.flash.add(self.gpa, &ctx.caps.layers, doc, fr) catch return;
        }
    }

    /// File extent `index`'s yank of `range` into slot `name` — captured now,
    /// while the range still holds what was yanked (and any identity riding
    /// it). A second yank by the same extent replaces its first.
    pub fn yank(
        self: *Stage,
        bank: *Register.Bank,
        name: u8,
        index: usize,
        subs: ?*const subbuffer.SubBuffers,
        doc: *const Document,
        range: Document.Range,
        bytes: []const u8,
        linewise: bool,
    ) Allocator.Error!void {
        if (name >= Register.Bank.slot_count) return;
        self.bank = bank;
        var value: Register = .empty;
        errdefer value.deinit(self.gpa);
        try value.yank(self.gpa, subs, doc, range, bytes, linewise);
        const list = &self.yanks[name];
        for (list.items) |*piece| if (piece.index == index) {
            piece.value.deinit(self.gpa);
            piece.value = value;
            return;
        };
        try list.append(self.gpa, .{ .index = index, .value = value });
    }

    /// Land the mapping: every staged slot, one value per extent that
    /// yanked, in document order; and the flash.
    pub fn commit(self: *Stage, ctx: *command.Context, alive: bool) void {
        self.landFlash(ctx, alive);
        const bank = self.bank orelse return;
        for (&self.yanks, 0..) |*list, slot| {
            if (list.items.len == 0) continue;
            std.mem.sort(Piece, list.items, {}, struct {
                fn lt(_: void, a: Piece, b: Piece) bool {
                    return a.index < b.index;
                }
            }.lt);
            const parts = self.gpa.alloc(*const Register, list.items.len) catch continue;
            defer self.gpa.free(parts);
            for (list.items, 0..) |*piece, i| parts[i] = &piece.value;
            bank.putEach(self.gpa, @intCast(slot), parts) catch {};
        }
    }
};

// ── The mapping ──────────────────────────────────────────────────────

/// Run `cmd` for `args` against the selection of the entry `ctx` is about:
/// once, or once per extent/target, or not at all (a refusal). The body of
/// `command.run` past name resolution.
pub fn run(ctx: *command.Context, cmd: *const command.Command, args: []const command.Value) anyerror!command.Value {
    if (explicitSubject(args)) {
        // A range names its subject — but on several extents, only a run
        // that owns one (a visit) or a command that took the set on may name
        // it. Anywhere else (an undeclared caller's callback, a bare
        // dispatch) the range is one extent's among several, chosen by no
        // declaration: the silent act-on-the-primary bug, refused.
        if (ctx.visit == null and !ctx.reading_set and shapeOf(ctx).count > 1) return error.UndeclaredMapping;
        return cmd.handler(ctx, cmd.data, args);
    }
    const over = if (cmd.arity) |a| switch (a) {
        .each => |e| e.over,
        .whole, .homogeneous => null,
    } else null;
    if (ctx.visit) |v| {
        // Nested in a run: the visited extent is the selection. A command
        // that maps over targets still finds this one's first.
        const target = over orelse return cmd.handler(ctx, cmd.data, args);
        return runOnTarget(ctx, cmd, args, target, v);
    }
    const shape = shapeOf(ctx);
    if (admits(cmd.arity, shape)) |refused| return refused;
    const each = if (cmd.arity) |a| switch (a) {
        .whole, .homogeneous => {
            // It reads the set — however many extents it grows or finds.
            const was = ctx.reading_set;
            ctx.reading_set = true;
            defer ctx.reading_set = was;
            return cmd.handler(ctx, cmd.data, args);
        },
        .each => |e| e,
    } else return cmd.handler(ctx, cmd.data, args); // undeclared, admitted: one extent
    // One extent is the degenerate case; one ROW with a target to find is
    // too — there is no text to find it in, and nothing to map.
    if (shape.count <= 1 and (over == null or !shape.text)) return cmd.handler(ctx, cmd.data, args);
    const entry = ctx.entry() orelse return cmd.handler(ctx, cmd.data, args);
    const ed = entry.textEditor() orelse return mapRows(ctx, cmd, args, each);
    return mapText(ctx, cmd, args, entry.ref(), ed, each);
}

/// Inside a run: find the visited extent's target, then run on it — the
/// one-extent case of `mapTargets`, under the run's own undo unit and stage.
fn runOnTarget(ctx: *command.Context, cmd: *const command.Command, args: []const command.Value, over: []const u8, v: *Visit) anyerror!command.Value {
    const was = v.targeting;
    v.targeting = true;
    const rv = command.run(ctx.commands, ctx, over, &.{}) catch |e| {
        v.targeting = was;
        return e;
    };
    v.targeting = was;
    const doc = ctx.document() orelse return .nil;
    _ = try targetOf(rv, doc) orelse return .nil;
    const full = try ctx.gpa.alloc(command.Value, args.len + 1);
    defer ctx.gpa.free(full);
    full[0] = rv;
    @memcpy(full[1..], args);
    return cmd.handler(ctx, cmd.data, full);
}

fn explicitSubject(args: []const command.Value) bool {
    for (args) |a| switch (a) {
        .range, .anchor => return true,
        else => {},
    };
    return false;
}

const HeadHandle = @FieldType(Editor.Selection, "head");

fn indexOf(ed: *const Editor, head: HeadHandle) ?usize {
    for (ed.selections.items, 0..) |sel, i| if (sel.head == head) return i;
    return null;
}

/// The editor a mapping began on, while it is still the one this dispatch
/// addresses: a run may switch or close the entry, and the mapping then stops.
fn stillOn(ctx: *command.Context, at: anytype, ed: *Editor) bool {
    const b = ctx.buffers.resolve(at) orelse return false;
    const now = b.textEditor() orelse return false;
    const current = (ctx.entry() orelse return false).textEditor() orelse return false;
    return now == ed and current == ed;
}

/// Map over text extents. Handles, not indices, name the extents meanwhile:
/// a run may reshape the set, and a head handle is an extent's identity.
fn mapText(
    ctx: *command.Context,
    cmd: *const command.Command,
    args: []const command.Value,
    at: anytype,
    ed: *Editor,
    each: Arity.Each,
) anyerror!command.Value {
    const gpa = ctx.gpa;
    const n = ed.selectionCount();
    const heads = try gpa.alloc(HeadHandle, n);
    defer gpa.free(heads);
    for (heads, ed.selections.items) |*h, sel| h.* = sel.head;
    const primary_head = ed.selections.items[ed.primary].head;

    var stage = Stage.init(gpa);
    defer stage.deinit();
    ed.history.beginUnit();
    ed.beginVisit();
    defer {
        ctx.visit = null;
        const still = if (ctx.buffers.resolve(at)) |b| b.textEditor() else null;
        if (still) |s| {
            if (indexOf(s, primary_head)) |i| s.visit(i) else s.visit(@min(s.primary, s.selectionCount() - 1));
            s.endVisit();
            s.history.endUnit();
        }
        // What the runs yanked and flashed lands once, as the mapping ends.
        stage.commit(ctx, still == ed);
    }

    return if (each.over) |over|
        try mapTargets(ctx, cmd, args, at, ed, heads, over, each.merge, &stage)
    else
        try mapExtents(ctx, cmd, args, at, ed, heads, &stage);
}

/// `.each` over the extents themselves: last first, so a run's edits never
/// move an extent still to come.
fn mapExtents(
    ctx: *command.Context,
    cmd: *const command.Command,
    args: []const command.Value,
    at: anytype,
    ed: *Editor,
    heads: []const HeadHandle,
    stage: *Stage,
) anyerror!command.Value {
    var result: command.Value = .nil;
    var i = heads.len;
    while (i > 0) {
        i -= 1;
        if (!stillOn(ctx, at, ed)) break;
        const idx = indexOf(ed, heads[i]) orelse continue;
        ed.visit(idx);
        ed.clearGoal(); // a vertical aim is one caret's, never shared
        var v: Visit = .{ .index = i, .count = heads.len, .remaining = i, .stage = stage };
        ctx.visit = &v;
        result = try cmd.handler(ctx, cmd.data, args);
    }
    return result;
}

const Target = struct {
    /// The extent (document order) that produced it.
    producer: usize,
    start: usize,
    end: usize,
    anchors: ?Document.RangeAnchors = null,
};

/// What a target command answered, as a range of `doc`: null for `.nil` (this
/// extent has no target), an error for anything else. A finder answering a
/// non-range, or a range of another document, is a broken declaration, and
/// running the command on fewer targets would hide it.
fn targetOf(rv: command.Value, doc: *Document) error{TargetNotARange}!?Document.Range {
    return switch (rv) {
        .nil => null,
        .range => |r| r.resolve(doc) orelse error.TargetNotARange,
        else => error.TargetNotARange,
    };
}

/// Settle `targets` in place and answer how many are kept, in document order
/// (the longer first at one start): identical ones once, nested ones each, a
/// partial overlap refused — or, with `merge`, unioned, touching ones too. A
/// target is checked against EVERY kept one still open at its start (a
/// stack: kept targets nest by construction), not only the last kept, so
/// `[0,10] [2,3] [5,12]` refuses: `[5,12]` clears `[2,3]` but not `[0,10]`.
fn settle(gpa: Allocator, targets: []Target, merge: bool) (Allocator.Error || Refusal)!usize {
    std.mem.sort(Target, targets, {}, struct {
        fn lt(_: void, a: Target, b: Target) bool {
            return a.start < b.start or (a.start == b.start and a.end > b.end);
        }
    }.lt);
    var m: usize = 0;
    if (merge) {
        // Unions stay disjoint, so the last kept is the only one to meet.
        for (targets) |t| {
            if (m > 0 and t.start <= targets[m - 1].end) {
                targets[m - 1].end = @max(targets[m - 1].end, t.end);
                continue;
            }
            targets[m] = t;
            m += 1;
        }
        return m;
    }
    // Indices of the kept targets open at the current start, outermost first.
    const open = try gpa.alloc(usize, targets.len);
    defer gpa.free(open);
    var depth: usize = 0;
    for (targets) |t| {
        if (m > 0 and t.start == targets[m - 1].start and t.end == targets[m - 1].end) continue;
        while (depth > 0 and targets[open[depth - 1]].end <= t.start) depth -= 1;
        if (depth > 0 and t.end > targets[open[depth - 1]].end) return error.OverlappingTargets;
        targets[m] = t;
        open[depth] = m;
        depth += 1;
        m += 1;
    }
    return m;
}

/// `.each` over targets: find every extent's target on the untouched text,
/// settle overlaps, then run once per target, last first.
fn mapTargets(
    ctx: *command.Context,
    cmd: *const command.Command,
    args: []const command.Value,
    at: anytype,
    ed: *Editor,
    heads: []const HeadHandle,
    over: []const u8,
    merge: bool,
    stage: *Stage,
) anyerror!command.Value {
    const gpa = ctx.gpa;
    const doc = &ed.doc;
    var targets: std.ArrayList(Target) = .empty;
    defer {
        for (targets.items) |t| if (t.anchors) |a| {
            doc.removeAnchor(a.start);
            doc.removeAnchor(a.end);
        };
        targets.deinit(gpa);
    }
    // Phase one: every extent's target, nothing edited. A target command's
    // failure is the mapping's: a misspelled `over`, or a finder that errors,
    // refuses the command rather than quietly shrinking the set it runs on.
    // Only an extent with NO target (`.nil`) is skipped.
    for (heads, 0..) |h, i| {
        if (!stillOn(ctx, at, ed)) return .nil;
        const idx = indexOf(ed, h) orelse continue;
        ed.visit(idx);
        var v: Visit = .{ .index = i, .count = heads.len, .remaining = heads.len, .targeting = true, .stage = stage };
        ctx.visit = &v;
        const rv = try command.run(ctx.commands, ctx, over, &.{});
        ctx.visit = null;
        const r = try targetOf(rv, doc) orelse continue;
        try targets.append(gpa, .{ .producer = i, .start = r.start, .end = r.end });
    }
    ctx.visit = null;
    targets.shrinkRetainingCapacity(try settle(gpa, targets.items, merge));
    for (targets.items) |*t| t.anchors = try doc.addRangeAnchors(gpa, .{ .start = t.start, .end = t.end });

    // Phase two: the command per target, last first.
    const full = try gpa.alloc(command.Value, args.len + 1);
    defer gpa.free(full);
    @memcpy(full[1..], args);
    var result: command.Value = .nil;
    var k = targets.items.len;
    while (k > 0) {
        k -= 1;
        if (!stillOn(ctx, at, ed)) break;
        const t = targets.items[k];
        if (indexOf(ed, heads[t.producer])) |idx| ed.visit(idx);
        ed.clearGoal();
        full[0] = .{ .range = .{ .document = doc, .start = t.anchors.?.start, .end = t.anchors.?.end } };
        var v: Visit = .{ .index = t.producer, .count = heads.len, .remaining = k, .stage = stage };
        ctx.visit = &v;
        result = try cmd.handler(ctx, cmd.data, full);
    }
    return result;
}

// ── Rows ─────────────────────────────────────────────────────────────

const Rows = Head.SceneSelection.Rows;

/// Where a row extent sits in its view's focus order: its first row.
fn orderOf(order: []const semantic_model.scene.NodeId, r: Rows) usize {
    var first: usize = order.len;
    for (order, 0..) |id, i| if (id == r.anchor or id == r.head) {
        first = i;
        break;
    };
    return first;
}

/// Focus row extent `r` as THE selection of the scene: its head focused,
/// grown from its anchor, nothing marked beside it. False when its head is
/// gone from the view.
fn focusRows(ctx: *command.Context, instance: anytype, r: Rows) bool {
    const focus = &ctx.head.scene_selection;
    var storage: [1026]semantic_model.scene.NodeId = undefined;
    const path = (instance.focusPath(r.head, &storage) catch return false) orelse return false;
    focus.others.clearRetainingCapacity();
    focus.set(ctx.gpa, path) catch return false;
    focus.anchor = if (r.anchor != r.head and instance.containsFocusable(r.anchor)) r.anchor else null;
    return true;
}

/// Map over row extents: last first in the view's order, each run with its
/// extent as the scene's one selection. The set is put back afterwards —
/// every extent whose rows are still there, the primary focused.
fn mapRows(ctx: *command.Context, cmd: *const command.Command, args: []const command.Value, each: Arity.Each) anyerror!command.Value {
    // A target is found by a range command over text; a scene has none, and
    // `admits` refused the command before any mapping began.
    std.debug.assert(each.over == null);
    const gpa = ctx.gpa;
    const focus = &ctx.head.scene_selection;
    const services = ctx.semantic orelse return cmd.handler(ctx, cmd.data, args);
    const view = focus.view orelse return cmd.handler(ctx, cmd.data, args);
    const instance = services.views.get(view) orelse return cmd.handler(ctx, cmd.data, args);
    const primary = focus.primaryRows() orelse return cmd.handler(ctx, cmd.data, args);

    const others = try gpa.dupe(Rows, focus.others.items);
    defer gpa.free(others);
    const extents = try gpa.alloc(Rows, others.len + 1);
    defer gpa.free(extents);
    @memcpy(extents[0..others.len], others);
    extents[others.len] = primary;
    const order = instance.focus_order;
    std.mem.sort(Rows, extents, order, struct {
        fn lt(o: []const semantic_model.scene.NodeId, a: Rows, b: Rows) bool {
            return orderOf(o, a) < orderOf(o, b);
        }
    }.lt);

    var primary_at: usize = 0;
    for (extents, 0..) |r, i| if (std.meta.eql(r, primary)) {
        primary_at = i;
    };

    var stage = Stage.init(gpa);
    defer stage.deinit();
    defer {
        ctx.visit = null;
        stage.commit(ctx, true);
        // Put the set back as the runs left it, as far as its rows still
        // exist: a run may have republished the view.
        if (services.views.get(view)) |now| {
            _ = focusRows(ctx, now, extents[primary_at]);
            for (extents, 0..) |r, i| {
                if (i == primary_at or !now.containsFocusable(r.head) or !now.containsFocusable(r.anchor)) continue;
                focus.others.append(gpa, r) catch {};
            }
        }
    }
    var result: command.Value = .nil;
    var i = extents.len;
    while (i > 0) {
        i -= 1;
        const now = services.views.get(view) orelse break;
        if (!focusRows(ctx, now, extents[i])) continue;
        var v: Visit = .{ .index = i, .count = extents.len, .remaining = i, .stage = &stage };
        ctx.visit = &v;
        result = try cmd.handler(ctx, cmd.data, args);
        // What the run left its extent as (a mark set, a move made).
        if (focus.view) |still| if (still.eql(view)) {
            extents[i] = focus.primaryRows() orelse extents[i];
        };
    }
    return result;
}

// ── Reading and writing the one selection ────────────────────────────
// What the selection doors exchange: extents of either kind, the same record
// for a text entry and a scene. A row crosses as its place in the view's
// focus order — the address a guest can count with; the row's own identity
// stays with the view.

/// The selection of the entry `ctx` is about, in document (view) order, and
/// which extent is the primary. Inside a visit, the visited extent alone.
/// Empty for an entry with neither text nor a scene. Caller frees.
pub fn read(ctx: *command.Context, gpa: Allocator) Allocator.Error!struct { extents: []Extent, primary: usize } {
    const entry = ctx.entry() orelse return .{ .extents = &.{}, .primary = 0 };
    if (entry.textEditor()) |ed| {
        const visiting = ed.visiting > 0;
        const n: usize = if (visiting) 1 else ed.selectionCount();
        const base: usize = if (visiting) ed.primary else 0;
        const out = try gpa.alloc(Extent, n);
        for (out, 0..) |*x, i| {
            const e = ed.selectionEnds(base + i);
            x.* = .{ .kind = .text, .anchor = e.anchor, .head = e.head };
        }
        return .{ .extents = out, .primary = ed.primary - base };
    }
    const focus = &ctx.head.scene_selection;
    const services = ctx.semantic orelse return .{ .extents = &.{}, .primary = 0 };
    const instance = services.views.get(focus.view orelse return .{ .extents = &.{}, .primary = 0 }) orelse
        return .{ .extents = &.{}, .primary = 0 };
    const primary = focus.primaryRows() orelse return .{ .extents = &.{}, .primary = 0 };
    const order = instance.focus_order;
    const rows = try gpa.alloc(Rows, focus.others.items.len + 1);
    defer gpa.free(rows);
    @memcpy(rows[0..focus.others.items.len], focus.others.items);
    rows[rows.len - 1] = primary;
    std.mem.sort(Rows, rows, order, struct {
        fn lt(o: []const semantic_model.scene.NodeId, a: Rows, b: Rows) bool {
            return orderOf(o, a) < orderOf(o, b);
        }
    }.lt);
    const out = try gpa.alloc(Extent, rows.len);
    var at: usize = 0;
    for (rows, out, 0..) |r, *x, i| {
        if (std.meta.eql(r, primary)) at = i;
        x.* = .{
            .kind = .rows,
            .anchor = std.mem.indexOfScalar(semantic_model.scene.NodeId, order, r.anchor) orelse 0,
            .head = std.mem.indexOfScalar(semantic_model.scene.NodeId, order, r.head) orelse 0,
        };
    }
    return .{ .extents = out, .primary = at };
}

/// Replace the selection of the entry `ctx` is about with `extents` (at
/// least one), `primary` indexing into them — inside a visit, the visited
/// extent alone. The kind must be the entry's: text in a text entry, rows in
/// a scene. False (nothing changed) when it is not, or a row is not there.
pub fn write(ctx: *command.Context, gpa: Allocator, extents: []const Extent, primary: usize) Allocator.Error!bool {
    if (extents.len == 0) return false;
    const entry = ctx.entry() orelse return false;
    if (entry.textEditor()) |ed| {
        const ends = try gpa.alloc(Editor.Ends, extents.len);
        defer gpa.free(ends);
        for (extents, ends) |x, *e| {
            if (x.kind != .text) return false;
            e.* = .{ .anchor = @intCast(@min(x.anchor, std.math.maxInt(u32))), .head = @intCast(@min(x.head, std.math.maxInt(u32))) };
        }
        if (ed.visiting > 0) try ed.replaceVisited(gpa, ends) else try ed.setSelections(gpa, ends, primary);
        return true;
    }
    const focus = &ctx.head.scene_selection;
    const services = ctx.semantic orelse return false;
    const instance = services.views.get(focus.view orelse return false) orelse return false;
    const order = instance.focus_order;
    const rows = try gpa.alloc(Rows, extents.len);
    defer gpa.free(rows);
    for (extents, rows) |x, *r| {
        if (x.kind != .rows or x.anchor >= order.len or x.head >= order.len) return false;
        r.* = .{ .anchor = order[@intCast(x.anchor)], .head = order[@intCast(x.head)] };
    }
    const lead = @min(primary, rows.len - 1);
    if (!focusRows(ctx, instance, rows[lead])) return false;
    for (rows, 0..) |r, i| if (i != lead) try focus.others.append(gpa, r);
    return true;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "admits: one extent runs anything; several refuse the undeclared and mixed homogeneous" {
    try testing.expectEqual(@as(?Refusal, null), admits(null, .{}));
    try testing.expectEqual(@as(?Refusal, error.UndeclaredMapping), admits(null, .{ .count = 2 }));
    try testing.expectEqual(@as(?Refusal, null), admits(.whole, .{ .count = 2, .mixed = true }));
    try testing.expectEqual(@as(?Refusal, null), admits(Arity.each_extent, .{ .count = 3 }));
    try testing.expectEqual(@as(?Refusal, null), admits(.homogeneous, .{ .count = 3 }));
    try testing.expectEqual(@as(?Refusal, error.MixedExtents), admits(.homogeneous, .{ .count = 2, .mixed = true }));
}

test "arity wire codes round-trip" {
    for ([_]Arity{ Arity.each_extent, .whole, .homogeneous }) |a| {
        try testing.expectEqual(a.code(), Arity.fromCode(a.code(), "").?.code());
    }
    const over = Arity.fromCode(3, "lines").?;
    try testing.expectEqualStrings("lines", over.each.over.?);
    try testing.expect(!over.each.merge);
    try testing.expect(Arity.fromCode(4, "lines").?.each.merge);
    try testing.expect(Arity.fromCode(3, "") == null);
    try testing.expect(Arity.fromCode(9, "") == null);
}

// ── A mapping, end to end over core commands ────────────────────────

const TestHost = @import("TestHost.zig");

/// A target: the line THE selection's head is on. The anchors it answers
/// with belong to the document, which frees them with itself.
fn testLine(ctx: *command.Context, args: struct {}) anyerror!command.Value {
    _ = args;
    const ed = try ctx.textEditor();
    const at = ed.cursorOffset();
    const text = try ed.text().toOwnedSlice(ctx.gpa);
    defer ctx.gpa.free(text);
    const s = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |i| i + 1 else 0;
    const e = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    return live(ctx, ed, s, e);
}

/// A target: five bytes from THE selection's head — which, from two carets
/// three apart, overlap without either holding the other.
fn testTail(ctx: *command.Context, args: struct {}) anyerror!command.Value {
    _ = args;
    const ed = try ctx.textEditor();
    const at = ed.cursorOffset();
    return live(ctx, ed, at, @min(at + 5, ed.text().byteLen()));
}

fn live(ctx: *command.Context, ed: *Editor, s: usize, e: usize) anyerror!command.Value {
    const a = try ed.doc.addRangeAnchors(ctx.gpa, .{ .start = s, .end = e });
    return .{ .range = .{ .document = &ed.doc, .start = a.start, .end = a.end } };
}

/// The command mapped over targets: a `#` at the start of its range.
fn testMark(ctx: *command.Context, args: struct { r: command.Value }) anyerror!command.Value {
    const doc = ctx.document().?;
    const r = args.r.range.resolve(doc).?;
    try ctx.edit(.{ .start = r.start, .end = r.start }, "#");
    return .nil;
}

test "mapping: targets found per selection; identical ones run once, as one undo unit; a partial overlap refuses the command" {
    const gpa = testing.allocator;
    var env: TestHost = undefined;
    try TestHost.init(gpa, &env);
    defer env.deinit(gpa);
    env.ctx.user_initiated = true;
    _ = try env.commands.bind(gpa, "t-line", command.define("t-line", "", testLine).maps(Arity.each_extent));
    _ = try env.commands.bind(gpa, "t-tail", command.define("t-tail", "", testTail).maps(Arity.each_extent));
    _ = try env.commands.bind(gpa, "t-mark-lines", command.define("t-mark-lines", "", testMark).maps(.{ .each = .{ .over = "t-line" } }));
    _ = try env.commands.bind(gpa, "t-mark-tails", command.define("t-mark-tails", "", testMark).maps(.{ .each = .{ .over = "t-tail" } }));
    _ = try env.commands.bind(gpa, "t-undeclared", command.define("t-undeclared", "", testLine).maps(null));

    const ed = env.editor();
    try ed.insertText(gpa, "ab cd\nef\n");
    ed.placeCursor(0);
    // Two carets on line one, one on line two: two targets, not three.
    try ed.setSelections(gpa, &.{ .{ .anchor = 0, .head = 0 }, .{ .anchor = 3, .head = 3 }, .{ .anchor = 6, .head = 6 } }, 0);
    _ = try command.run(&env.commands, &env.ctx, "t-mark-lines", &.{});
    const once = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(once);
    try testing.expectEqualStrings("#ab cd\n#ef\n", once);
    // One unit: one undo takes both back. Every selection survives.
    try testing.expectEqual(@as(usize, 3), ed.selectionCount());
    try testing.expect(try ed.undo(gpa, .user_driven));
    const back = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(back);
    try testing.expectEqualStrings("ab cd\nef\n", back);

    // Tails of carets 0 and 3 overlap without nesting: refused, not half-run.
    try ed.setSelections(gpa, &.{ .{ .anchor = 0, .head = 0 }, .{ .anchor = 3, .head = 3 } }, 0);
    try testing.expectError(error.OverlappingTargets, command.run(&env.commands, &env.ctx, "t-mark-tails", &.{}));
    const untouched = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(untouched);
    try testing.expectEqualStrings("ab cd\nef\n", untouched);

    // An undeclared command never runs on several selections.
    try testing.expectError(error.UndeclaredMapping, command.run(&env.commands, &env.ctx, "t-undeclared", &.{}));
}

/// A `.whole` command that hands `t-mark-at` the range of the set's FIRST
/// extent — a command that read the set and chose among it.
fn testWholeFirst(ctx: *command.Context, args: struct {}) anyerror!command.Value {
    _ = args;
    const ed = try ctx.textEditor();
    const first = ed.selectionEnds(0);
    const rv = try live(ctx, ed, first.head, first.head);
    return command.run(ctx.commands, ctx, "t-mark-at", &.{rv});
}

test "an explicit range on several extents runs only where a visit or a set-reading command chose it" {
    const gpa = testing.allocator;
    var env: TestHost = undefined;
    try TestHost.init(gpa, &env);
    defer env.deinit(gpa);
    env.ctx.user_initiated = true;
    _ = try env.commands.bind(gpa, "t-mark-at", command.define("t-mark-at", "", testMark).maps(null));
    _ = try env.commands.bind(gpa, "t-whole-first", command.define("t-whole-first", "", testWholeFirst).maps(.whole));

    const ed = env.editor();
    try ed.insertText(gpa, "ab\ncd\n");
    try ed.setSelections(gpa, &.{ .{ .anchor = 0, .head = 0 }, .{ .anchor = 3, .head = 3 } }, 1);

    // Handed a range by nobody that took the set on: which of the two it is
    // was chosen by no declaration, so it is refused, not run on one.
    const rv = try live(&env.ctx, ed, 3, 3);
    try testing.expectError(error.UndeclaredMapping, command.run(&env.commands, &env.ctx, "t-mark-at", &.{rv}));
    const untouched = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(untouched);
    try testing.expectEqualStrings("ab\ncd\n", untouched);

    // A `.whole` command read the set and chose: its range runs.
    _ = try command.run(&env.commands, &env.ctx, "t-whole-first", &.{});
    const chosen = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(chosen);
    try testing.expectEqualStrings("#ab\ncd\n", chosen);

    // One extent is the degenerate case: a range runs.
    try ed.setSelections(gpa, &.{.{ .anchor = 0, .head = 0 }}, 0);
    _ = try command.run(&env.commands, &env.ctx, "t-mark-at", &.{rv});
    const one = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(one);
    try testing.expectEqualStrings("#ab\n#cd\n", one);
}

/// A target per caret, from a table: caret 0 → [0,10], caret 2 → [2,3],
/// caret 5 → [5,12]. Any other caret has none.
fn testTable(ctx: *command.Context, args: struct {}) anyerror!command.Value {
    _ = args;
    const ed = try ctx.textEditor();
    return switch (ed.cursorOffset()) {
        0 => live(ctx, ed, 0, 10),
        2 => live(ctx, ed, 2, 3),
        5 => live(ctx, ed, 5, 12),
        else => .nil,
    };
}

fn testFails(ctx: *command.Context, args: struct {}) anyerror!command.Value {
    _ = ctx;
    _ = args;
    return error.FinderBroke;
}

test "mapping: a target overlapping an earlier one refuses, though it clears the last kept" {
    const gpa = testing.allocator;
    var env: TestHost = undefined;
    try TestHost.init(gpa, &env);
    defer env.deinit(gpa);
    env.ctx.user_initiated = true;
    _ = try env.commands.bind(gpa, "t-table", command.define("t-table", "", testTable).maps(Arity.each_extent));
    _ = try env.commands.bind(gpa, "t-mark-table", command.define("t-mark-table", "", testMark).maps(.{ .each = .{ .over = "t-table" } }));
    const ed = env.editor();
    try ed.insertText(gpa, "0123456789abcdef\n");
    // [0,10] holds [2,3]; [5,12] overlaps [0,10] partially: refused, whole.
    try ed.setSelections(gpa, &.{ .{ .anchor = 0, .head = 0 }, .{ .anchor = 2, .head = 2 }, .{ .anchor = 5, .head = 5 } }, 0);
    try testing.expectError(error.OverlappingTargets, command.run(&env.commands, &env.ctx, "t-mark-table", &.{}));
    const text = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(text);
    try testing.expectEqualStrings("0123456789abcdef\n", text);
}

test "mapping: a target finder's failure refuses the command, and a misspelled over is no silent no-op" {
    const gpa = testing.allocator;
    var env: TestHost = undefined;
    try TestHost.init(gpa, &env);
    defer env.deinit(gpa);
    env.ctx.user_initiated = true;
    _ = try env.commands.bind(gpa, "t-fails", command.define("t-fails", "", testFails).maps(Arity.each_extent));
    _ = try env.commands.bind(gpa, "t-mark-fails", command.define("t-mark-fails", "", testMark).maps(.{ .each = .{ .over = "t-fails" } }));
    _ = try env.commands.bind(gpa, "t-mark-typo", command.define("t-mark-typo", "", testMark).maps(.{ .each = .{ .over = "t-lnie" } }));
    const ed = env.editor();
    try ed.insertText(gpa, "ab\ncd\n");
    try ed.setSelections(gpa, &.{ .{ .anchor = 0, .head = 0 }, .{ .anchor = 3, .head = 3 } }, 0);
    try testing.expectError(error.FinderBroke, command.run(&env.commands, &env.ctx, "t-mark-fails", &.{}));
    try testing.expectError(error.UnknownCommand, command.run(&env.commands, &env.ctx, "t-mark-typo", &.{}));
}

test "admits: each-over-targets refuses several rows, with its own reason" {
    const over: Arity = .{ .each = .{ .over = "lines" } };
    try testing.expectEqual(@as(?Refusal, error.UntargetableExtents), admits(over, .{ .count = 2, .text = false }));
    try testing.expectEqual(@as(?Refusal, null), admits(over, .{ .count = 2 }));
    try testing.expectEqual(@as(?Refusal, null), admits(Arity.each_extent, .{ .count = 2, .text = false }));
    try testing.expectEqualStrings("text-selection", reason(asRefusal(error.UntargetableExtents).?).code);
    try testing.expect(asRefusal(error.OutOfMemory) == null);
}

test "settle: every target meets every one open at its start; merging unions" {
    const gpa = testing.allocator;
    var three = [_]Target{ .{ .producer = 0, .start = 0, .end = 10 }, .{ .producer = 1, .start = 2, .end = 3 }, .{ .producer = 2, .start = 5, .end = 12 } };
    try testing.expectError(error.OverlappingTargets, settle(gpa, &three, false));
    // Nested each run, identical once, touching is not overlapping.
    var nested = [_]Target{ .{ .producer = 0, .start = 2, .end = 3 }, .{ .producer = 1, .start = 0, .end = 10 }, .{ .producer = 2, .start = 5, .end = 9 }, .{ .producer = 3, .start = 0, .end = 10 }, .{ .producer = 4, .start = 10, .end = 12 } };
    try testing.expectEqual(@as(usize, 4), try settle(gpa, &nested, false));
    try testing.expectEqual(@as(usize, 0), nested[0].start);
    try testing.expectEqual(@as(usize, 10), nested[3].start);
    // A nested one partially overlapping its sibling still refuses.
    var siblings = [_]Target{ .{ .producer = 0, .start = 0, .end = 10 }, .{ .producer = 1, .start = 2, .end = 5 }, .{ .producer = 2, .start = 4, .end = 7 } };
    try testing.expectError(error.OverlappingTargets, settle(gpa, &siblings, false));
    var lines = [_]Target{ .{ .producer = 0, .start = 0, .end = 10 }, .{ .producer = 1, .start = 2, .end = 3 }, .{ .producer = 2, .start = 5, .end = 12 }, .{ .producer = 3, .start = 12, .end = 14 }, .{ .producer = 4, .start = 20, .end = 22 } };
    try testing.expectEqual(@as(usize, 2), try settle(gpa, &lines, true));
    try testing.expectEqual(@as(usize, 14), lines[0].end);
}
