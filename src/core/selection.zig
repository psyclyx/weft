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
//! a motion's range).

const std = @import("std");
const Allocator = std.mem.Allocator;

const command = @import("command.zig");
const Editor = @import("Editor.zig");
const Register = @import("register.zig");
const subbuffer = @import("subbuffer.zig");
const Document = @import("Document.zig");

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
};

pub const Refusal = error{
    /// A command that declares no mapping met several extents.
    UndeclaredMapping,
    /// A `.homogeneous` command met extents of different kinds.
    MixedExtents,
    /// An `.each` command's targets partially overlap.
    OverlappingTargets,
};

/// Whether a command of `arity` can run on `shape`, else why not. The ONE
/// reading dispatch refuses by and availability disables by, so an offer the
/// toolbar greys is exactly a command dispatch would refuse.
pub fn admits(arity: ?Arity, shape: Shape) ?Refusal {
    if (shape.count <= 1) return null;
    const a = arity orelse return error.UndeclaredMapping;
    return switch (a) {
        .homogeneous => if (shape.mixed) error.MixedExtents else null,
        .each, .whole => null,
    };
}

/// The reason code and sentence a refusal is SHOWN by — dispatch's echo,
/// the offers' disabled reason, explain and which-key all read these.
pub fn reason(r: Refusal) struct { code: []const u8, message: []const u8 } {
    return switch (r) {
        error.UndeclaredMapping => .{ .code = "one-selection", .message = "acts on one selection; several are selected" },
        error.MixedExtents => .{ .code = "mixed-selection", .message = "needs selections of one kind" },
        error.OverlappingTargets => .{ .code = "overlapping-targets", .message = "the selections' targets overlap" },
    };
}

/// The shape of the selection of the entry `ctx` is about. Inside a visit
/// there is exactly one extent, whatever the entry holds.
pub fn shapeOf(ctx: *command.Context) Shape {
    if (ctx.visit != null) return .{};
    const entry = ctx.entry() orelse return .{};
    if (entry.textEditor()) |ed| return .{ .count = ed.selectionCount() };
    return .{};
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
            Register.putEachIn(bank, self.gpa, @intCast(slot), parts) catch {};
        }
    }
};

// ── The mapping ──────────────────────────────────────────────────────

/// Run `cmd` for `args` against the selection of the entry `ctx` is about:
/// once, or once per extent/target, or not at all (a refusal). The body of
/// `command.run` past name resolution.
pub fn run(ctx: *command.Context, cmd: *const command.Command, args: []const command.Value) anyerror!command.Value {
    if (explicitSubject(args)) return cmd.handler(ctx, cmd.data, args);
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
    if (shape.count <= 1 and over == null) return cmd.handler(ctx, cmd.data, args);
    const arity = cmd.arity.?; // admitted with several extents: declared
    const each = switch (arity) {
        .whole, .homogeneous => return cmd.handler(ctx, cmd.data, args),
        .each => |e| e,
    };
    const entry = ctx.entry() orelse return cmd.handler(ctx, cmd.data, args);
    const ed = entry.textEditor() orelse return cmd.handler(ctx, cmd.data, args);
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
    if (rv != .range) return .nil;
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
    // Phase one: every extent's target, nothing edited.
    for (heads, 0..) |h, i| {
        if (!stillOn(ctx, at, ed)) return .nil;
        const idx = indexOf(ed, h) orelse continue;
        ed.visit(idx);
        var v: Visit = .{ .index = i, .count = heads.len, .remaining = heads.len, .targeting = true, .stage = stage };
        ctx.visit = &v;
        const rv = command.run(ctx.commands, ctx, over, &.{}) catch continue;
        ctx.visit = null;
        if (rv != .range) continue;
        const r = rv.range.resolve(doc) orelse continue;
        try targets.append(gpa, .{ .producer = i, .start = r.start, .end = r.end });
    }
    ctx.visit = null;
    std.mem.sort(Target, targets.items, {}, struct {
        fn lt(_: void, a: Target, b: Target) bool {
            return a.start < b.start or (a.start == b.start and a.end > b.end);
        }
    }.lt);
    // Settle: identical once; nested each; partial overlap merged or refused.
    var m: usize = 0;
    for (targets.items) |t| {
        if (m > 0) {
            const prev = &targets.items[m - 1];
            if (t.start == prev.start and t.end == prev.end) continue;
            const overlaps = t.start < prev.end or (merge and t.start == prev.end);
            const nested = t.end <= prev.end;
            if (overlaps and (merge or !nested)) {
                if (!merge) return error.OverlappingTargets;
                prev.end = @max(prev.end, t.end);
                continue;
            }
        }
        targets.items[m] = t;
        m += 1;
    }
    targets.shrinkRetainingCapacity(m);
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
