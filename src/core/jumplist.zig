//! The jumplist — a head's position history (vim's C-o/C-i, helix's C-o/C-i).
//!
//! One entry is a workspace entry (a generation-checked `Buffers.Ref`) plus,
//! when the entry holds text, an ANCHOR in its document: the offset rides every
//! edit (`Document.addAnchor`), so an insert above a remembered spot does not
//! send the jump back to the wrong line. An entry whose buffer has closed no
//! longer resolves and is skipped, never landed on.
//!
//! Who decides what is a jump: the grammar, for anything inside one entry (a
//! search, a goto, a big motion — `wl_jump_push`); core, for moving between
//! entries, because only core sees every such move (`Buffers.switchTo` pushes
//! the position being left). Moving along the list is not itself a jump.
//!
//! Browser semantics rather than vim's keep-everything list: pushing while
//! part-way back drops the forward half (helix does the same). The first
//! `back` from the tip records where you are, so `forward` can return there.
//!
//! **Not `navigate-back`.** `buffer-back` (a tool's `q`, `std.navigation.back`'s
//! core route) LEAVES the current entry for the one before it, always — that is
//! what closing a tool means. The jumplist's previous position is often in the
//! same entry (the search you ran in the git status buffer), which would make
//! `q` a no-op there. Two verbs, then, over two facts: "the entry I came from"
//! (`Buffers.prev_id`, a slot, not a history) and "where I have been" (this).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Buffers = @import("Buffers.zig");
const Head = @import("Head.zig");
const Keymap = @import("Keymap.zig");
const Document = @import("Document.zig");

/// Oldest entries fall off past this — a history, not a log.
pub const cap = 100;

pub const Jump = struct {
    entry: Buffers.Ref,
    /// The remembered offset, anchored in the entry's document. Null for an
    /// entry that holds no text (a tool view): jumping there just focuses it.
    anchor: ?Document.AnchorHandle = null,
};

pub const JumpList = struct {
    items: std.ArrayList(Jump) = .empty,
    /// The entry `back` steps from: `items.len` at the tip, else the index of
    /// the position the last `back`/`forward` landed on.
    pos: usize = 0,
    /// Set while the list itself is moving the head, so the entry switch that
    /// travel causes is not recorded as a new jump.
    traveling: bool = false,

    pub const empty: JumpList = .{};

    /// Frees the list. Anchors stay in their documents, which own them and
    /// free them with the document; a head outliving its buffers has none left
    /// to release.
    pub fn deinit(self: *JumpList, gpa: Allocator) void {
        self.items.deinit(gpa);
        self.* = .{};
    }
};

/// Where `buffers`' active entry is right now, as a position to remember.
pub const Here = struct { entry: Buffers.Ref, offset: ?usize };

pub fn here(buffers: *Buffers) Here {
    const b = buffers.active();
    return .{ .entry = b.ref(), .offset = if (b.textEditor()) |ed| ed.cursorOffset() else null };
}

/// The live offset of `jump`, or null when its entry is gone. An entry with
/// no anchor resolves to offset 0 for comparison; `null` means DEAD.
fn resolve(buffers: *Buffers, jump: Jump) ?struct { buffer: *Buffers.Buffer, offset: ?usize } {
    const b = buffers.resolve(jump.entry) orelse return null;
    const a = jump.anchor orelse return .{ .buffer = b, .offset = null };
    const ed = b.textEditor() orelse return .{ .buffer = b, .offset = null };
    return .{ .buffer = b, .offset = ed.doc.anchorOffset(a) };
}

fn release(buffers: *Buffers, jump: Jump) void {
    const a = jump.anchor orelse return;
    const b = buffers.resolve(jump.entry) orelse return;
    if (b.textEditor()) |ed| ed.doc.removeAnchor(a);
}

fn same(buffers: *Buffers, jump: Jump, at: Here) bool {
    if (jump.entry.id != at.entry.id or jump.entry.generation != at.entry.generation) return false;
    const r = resolve(buffers, jump) orelse return false;
    return std.meta.eql(r.offset, at.offset);
}

/// Record `at` as a jump. Drops any forward half first; a push equal to the
/// newest entry is a no-op, so pressing `n` on the only match does not fill
/// the list with one position.
pub fn push(list: *JumpList, gpa: Allocator, buffers: *Buffers, at: Here) Allocator.Error!void {
    if (list.traveling) return;
    // Part-way back, the entry the head stands on stays; what is after it goes.
    const keep = @min(list.pos + 1, list.items.items.len);
    while (list.items.items.len > keep) release(buffers, list.items.pop().?);
    try append(list, gpa, buffers, at);
    list.pos = list.items.items.len;
}

fn append(list: *JumpList, gpa: Allocator, buffers: *Buffers, at: Here) Allocator.Error!void {
    if (list.items.getLastOrNull()) |last| if (same(buffers, last, at)) return;
    const b = buffers.resolve(at.entry) orelse return;
    var jump: Jump = .{ .entry = at.entry };
    if (at.offset) |off| if (b.textEditor()) |ed| {
        jump.anchor = try ed.doc.addAnchor(gpa, @min(off, ed.text().byteLen()), .left);
    };
    errdefer if (jump.anchor) |a| b.textEditor().?.doc.removeAnchor(a);
    try list.items.append(gpa, jump);
    if (list.items.items.len > cap) {
        release(buffers, list.items.orderedRemove(0));
        if (list.pos > 0) list.pos -= 1;
    }
}

pub const Direction = enum { back, forward };

/// Move `count` live entries along the list and put the head there. Dead
/// entries (closed buffers) and entries equal to where the head already is
/// are stepped over without counting. Returns false, moving nothing, when
/// there is no such entry.
pub fn travel(
    list: *JumpList,
    gpa: Allocator,
    buffers: *Buffers,
    head: *Head,
    keymap: *const Keymap,
    dir: Direction,
    count: usize,
) !bool {
    const now = here(buffers);
    if (dir == .back and list.pos >= list.items.items.len) {
        // Leaving the tip: remember it, so `forward` can come back.
        try append(list, gpa, buffers, now);
        list.pos = list.items.items.len -| 1;
    }
    var i = list.pos;
    var left = @max(count, 1);
    var found: ?usize = null;
    while (left > 0) {
        const next = switch (dir) {
            .back => if (i == 0) break else i - 1,
            .forward => if (i + 1 >= list.items.items.len) break else i + 1,
        };
        i = next;
        const jump = list.items.items[i];
        if (resolve(buffers, jump) == null or same(buffers, jump, now)) continue;
        left -= 1;
        found = i;
    }
    const target = found orelse return false;
    list.pos = target;
    try goTo(list, gpa, buffers, head, keymap, list.items.items[target]);
    return true;
}

/// Land on entry `index` (a picker's choice). False when it is gone.
pub fn travelTo(list: *JumpList, gpa: Allocator, buffers: *Buffers, head: *Head, keymap: *const Keymap, index: usize) !bool {
    if (index >= list.items.items.len) return false;
    if (resolve(buffers, list.items.items[index]) == null) return false;
    if (list.pos >= list.items.items.len) {
        try append(list, gpa, buffers, here(buffers));
    }
    list.pos = index;
    try goTo(list, gpa, buffers, head, keymap, list.items.items[index]);
    return true;
}

fn goTo(list: *JumpList, gpa: Allocator, buffers: *Buffers, head: *Head, keymap: *const Keymap, jump: Jump) !void {
    const r = resolve(buffers, jump) orelse return;
    list.traveling = true;
    defer list.traveling = false;
    if (r.buffer.id != buffers.active_id) try buffers.switchTo(gpa, r.buffer.id, head, keymap);
    if (r.offset) |off| if (r.buffer.textEditor()) |ed| ed.placeCursor(off);
}

/// One row of `describe`: the entry's name, the 1-based line, and whether it
/// is where the list currently stands.
pub const Row = struct {
    index: usize,
    name: []const u8,
    line: ?usize,
    offset: ?usize,
    current: bool,
};

/// The live entries, newest first — what a picker lists. Dead entries are
/// left out. `out` is caller-owned scratch.
pub fn describe(list: *const JumpList, gpa: Allocator, buffers: *Buffers, out: *std.ArrayList(Row)) Allocator.Error!void {
    var i = list.items.items.len;
    while (i > 0) {
        i -= 1;
        const jump = list.items.items[i];
        const r = resolve(buffers, jump) orelse continue;
        var line: ?usize = null;
        if (r.offset) |off| if (r.buffer.textEditor()) |ed| {
            line = ed.text().offsetToPoint(off).row + 1;
        };
        try out.append(gpa, .{ .index = i, .name = r.buffer.name, .line = line, .offset = r.offset, .current = i == list.pos });
    }
}

// ── Commands ─────────────────────────────────────────────────────────
//
// `jump-back`/`jump-forward` take an optional count, as an integer or as the
// digits a grammar accumulated (`runStr`), so a count prefix reaches them from
// either plane. `jump-push` is the door a grammar with no guest code (a
// config's bound key) reaches `wl_jump_push` through.

const command = @import("command.zig");
const Context = command.Context;
const Value = command.Value;
const pick_types = @import("pick/types.zig");

/// A count argument: absent, an integer, or decimal digits. Anything else is
/// the caller's mistake, said out loud.
pub fn countArg(args: []const Value, i: usize) error{TypeMismatch}!usize {
    if (args.len <= i) return 1;
    return switch (args[i]) {
        .nil => 1,
        .integer => |n| if (n < 1) 1 else @intCast(n),
        .string => |s| if (s.len == 0) 1 else std.fmt.parseInt(usize, s, 10) catch return error.TypeMismatch,
        else => error.TypeMismatch,
    };
}

fn say(ctx: *Context, msg: []const u8) void {
    ctx.head.echo.clearRetainingCapacity();
    ctx.head.echo.appendSlice(ctx.gpa, msg) catch {};
}

fn travelCmd(comptime dir: Direction) fn (*Context, ?*anyopaque, []const Value) anyerror!Value {
    return struct {
        fn f(ctx: *Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
            _ = data;
            const n = try countArg(args, 0);
            if (!try travel(&ctx.head.jumps, ctx.gpa, ctx.buffers, ctx.head, ctx.keymap, dir, n))
                say(ctx, if (dir == .back) "jumplist: nothing older" else "jumplist: nothing newer");
            return .nil;
        }
    }.f;
}

fn cJumpPush(ctx: *Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
    _ = data;
    _ = args;
    try push(&ctx.head.jumps, ctx.gpa, ctx.buffers, here(ctx.buffers));
    return .nil;
}

/// `jumplist-pick`: every live entry, newest first, through the head's picker.
/// A row's key is its list index, so accepting lands on exactly that entry
/// even when two rows read alike.
fn cJumplistPick(ctx: *Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
    _ = data;
    _ = args;
    const gpa = ctx.gpa;
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    try describe(&ctx.head.jumps, gpa, ctx.buffers, &rows);
    if (rows.items.len == 0) {
        say(ctx, "jumplist: empty");
        return .nil;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try a.alloc(pick_types.Entry, rows.items.len);
    for (rows.items, entries) |r, *e| {
        e.* = .{
            .text = if (r.line) |line|
                try std.fmt.allocPrint(a, "{s}:{d}", .{ r.name, line })
            else
                try a.dupe(u8, r.name),
            .doc = if (r.current) "current" else "",
            .key = try std.fmt.allocPrint(a, "{d}", .{r.index}),
        };
    }
    const keys = try gpa.alloc(usize, rows.items.len);
    errdefer gpa.free(keys);
    for (rows.items, keys) |r, *k| k.* = r.index;
    const held = try gpa.create([]usize);
    errdefer gpa.destroy(held);
    held.* = keys;
    try ctx.head.pick.openWith(ctx, "jumps", entries, .{
        .handler = pickAccept,
        .cleanup = pickCleanup,
        .data = @ptrCast(held),
    }, .{ .category = "jump" });
    return .nil;
}

fn pickAccept(ctx: *Context, data: ?*anyopaque, outcome: pick_types.Outcome) anyerror!void {
    const keys: *[]usize = @ptrCast(@alignCast(data.?));
    const chosen = switch (outcome) {
        .candidate => |c| c.index,
        else => return,
    };
    if (chosen >= keys.len) return;
    if (!try travelTo(&ctx.head.jumps, ctx.gpa, ctx.buffers, ctx.head, ctx.keymap, keys.*[chosen]))
        say(ctx, "jumplist: that entry is gone");
}

fn pickCleanup(data: ?*anyopaque, gpa: Allocator) void {
    const keys: *[]usize = @ptrCast(@alignCast(data.?));
    gpa.free(keys.*);
    gpa.destroy(keys);
}

const count_arg: []const command.ArgSpec = &.{.{ .name = "count", .type = .nil, .optional = true }};

const table = [_]command.Command{
    .{ .name = "jump-back", .summary = "Go back along the jumplist (C-o).", .args = count_arg, .handler = travelCmd(.back) },
    .{ .name = "jump-forward", .summary = "Go forward along the jumplist (C-i).", .args = count_arg, .handler = travelCmd(.forward) },
    .{ .name = "jump-push", .summary = "Remember the caret as a jump.", .args = &.{}, .handler = cJumpPush },
    .{ .name = "jumplist-pick", .summary = "Pick a position from the jumplist.", .args = &.{}, .handler = cJumplistPick },
};

pub fn install(gpa: Allocator, commands: *command.Commands) !void {
    for (table) |cmd| _ = try commands.bind(gpa, cmd.name, cmd);
}

const t = std.testing;
const task = @import("task.zig");

const Fixture = struct {
    pool: *task.Pool,
    bufs: Buffers,
    km: Keymap = .empty,
    head: Head = .empty,

    fn init(self: *Fixture) !void {
        self.pool = try task.Pool.init(t.allocator, .{ .threads = 1 });
        self.bufs = try Buffers.init(t.allocator, self.pool, "user");
        self.km = .empty;
        self.head = .empty;
    }
    fn deinit(self: *Fixture) void {
        self.head.deinit(t.allocator);
        self.km.deinit(t.allocator);
        self.bufs.deinit(t.allocator);
        self.pool.deinit();
    }
    fn fill(self: *Fixture, id: Buffers.Id, text: []const u8) !void {
        const ed = self.bufs.get(id).?.textEditor().?;
        ed.placeCursor(0);
        try ed.insertText(t.allocator, text);
    }
    fn at(self: *Fixture, off: usize) void {
        self.bufs.active().textEditor().?.placeCursor(off);
    }
    fn cursor(self: *Fixture) usize {
        return self.bufs.active().textEditor().?.cursorOffset();
    }
    fn back(self: *Fixture) !bool {
        return travel(&self.head.jumps, t.allocator, &self.bufs, &self.head, &self.km, .back, 1);
    }
    fn forward(self: *Fixture) !bool {
        return travel(&self.head.jumps, t.allocator, &self.bufs, &self.head, &self.km, .forward, 1);
    }
    fn remember(self: *Fixture) !void {
        try push(&self.head.jumps, t.allocator, &self.bufs, here(&self.bufs));
    }
};

test "jumplist: push, back and forward within one entry" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.fill(0, "one\ntwo\nthree\nfour\n");
    f.at(0);
    try f.remember();
    f.at(8);
    try f.remember();
    f.at(14);
    try t.expect(try f.back()); // tip recorded, back to 8
    try t.expectEqual(@as(usize, 8), f.cursor());
    try t.expect(try f.back());
    try t.expectEqual(@as(usize, 0), f.cursor());
    try t.expect(!try f.back()); // nothing older
    try t.expect(try f.forward());
    try t.expectEqual(@as(usize, 8), f.cursor());
    try t.expect(try f.forward());
    try t.expectEqual(@as(usize, 14), f.cursor()); // the tip it remembered
    try t.expect(!try f.forward());
}

test "jumplist: an edit above a remembered spot moves the spot with it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.fill(0, "alpha\nbeta\n");
    f.at(6); // "beta"
    try f.remember();
    f.at(0);
    try f.bufs.active().textEditor().?.insertText(t.allocator, "new line\n");
    try t.expect(try f.back());
    try t.expectEqual(@as(usize, 15), f.cursor());
    try t.expectEqual(@as(u8, 'b'), f.bufs.active().textEditor().?.text().byteAt(15));
}

test "jumplist: switching entries records where you were; closed entries are skipped" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.fill(0, "scratch text\n");
    const a = try f.bufs.create(t.allocator, "a.zig");
    const b = try f.bufs.create(t.allocator, "b.zig");
    try f.fill(a, "in a\n");
    f.at(3);
    try f.bufs.switchTo(t.allocator, a, &f.head, &f.km); // pushes scratch@3
    try f.bufs.switchTo(t.allocator, b, &f.head, &f.km); // pushes a@0
    try t.expectEqual(@as(usize, 2), f.head.jumps.items.items.len);

    try t.expect(try f.back()); // b → a
    try t.expectEqual(a, f.bufs.active_id);
    try t.expect(try f.back()); // a → scratch@3
    try t.expectEqual(@as(Buffers.Id, 0), f.bufs.active_id);
    try t.expectEqual(@as(usize, 3), f.cursor());
    try t.expect(try f.forward());
    try t.expectEqual(a, f.bufs.active_id);

    // Close `a`: forward from scratch now steps over it to b.
    try t.expect(try f.back());
    try f.bufs.close(t.allocator, a, &f.head, &f.km);
    try t.expect(try f.forward());
    try t.expectEqual(b, f.bufs.active_id);
}

test "jumplist: a push part-way back drops the forward half" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.fill(0, "0123456789\n");
    for ([_]usize{ 1, 2, 3 }) |off| {
        f.at(off);
        try f.remember();
    }
    f.at(4);
    try t.expect(try f.back()); // at 3
    try t.expect(try f.back()); // at 2
    f.at(7);
    try f.remember(); // 1, 2, 7
    try t.expectEqual(@as(usize, 3), f.head.jumps.items.items.len);
    try t.expect(!try f.forward());
    try t.expect(try f.back());
    try t.expectEqual(@as(usize, 2), f.cursor());
}
