//! Provider answers, cached per version (doc/model.md §2.7).
//!
//! A frame never calls a guest. What a plugin says about a pane — its gutter
//! cells, its status segments — is ASKED for a version and CACHED here, keyed
//! by what the question was: the pane, the entry, the document revision, and
//! the facts and positions the ask carries. A frame draws the newest answer it
//! has for its pane, whether or not it was the answer to this frame's
//! question, and notes the question it had no answer to (`want`). After the
//! frame, the loop asks (`FrameBuilder.answerRequests`); an answer that lands
//! damages the view, so the next frame draws it.
//!
//! So an answer is at most one frame late, and a provider answering may act
//! like any other code: its edits land between frames, as the next version,
//! never inside the frame being drawn. That is what retired the draw-time
//! door allowlist (`contract.render_safe`).
//!
//! Nothing here knows a pane's geometry, a slot's schema, or how a plugin is
//! reached: a key is an opaque digest (`Key`), an ask is the exchange's own
//! type (`core.gutter.Ask`, `core.status_segment.Ask`), and an answer is the
//! decoded mesh vocabulary (`ui_mesh`).

const std = @import("std");
const core = @import("weft_core");
const ui_mesh = @import("weft_gfx").view.ui_mesh;

/// The question an answer is to, as a digest (`FrameBuilder`'s `gutterKey` /
/// `statusKey`). Equal keys are the same question; anything that could change
/// an answer is in the key, so an unequal key is a question not yet answered.
pub const Key = u64;

/// Which exchange a request or an answer belongs to.
pub const Slot = enum { gutter, status };

/// A question a frame had no answer to.
pub const Request = struct {
    pane: u32,
    entry: core.Buffers.Ref,
    key: Key,
    ask: Ask,

    pub const Ask = union(Slot) {
        gutter: core.gutter.Ask,
        status: core.status_segment.Ask,
    };

    fn same(a: Request, b: Request) bool {
        if (a.pane != b.pane or a.key != b.key or @as(Slot, a.ask) != @as(Slot, b.ask)) return false;
        return switch (a.ask) {
            .gutter => |g| g.first == b.ask.gutter.first,
            .status => true,
        };
    }
};

/// One stored answer: what the pane's providers said to one question.
pub const Entry = struct {
    pane: u32,
    key: Key,
    /// Store order: the newest answer wins a lookup.
    stamp: u64,
    /// Owns every byte of `answer`.
    arena: std.heap.ArenaAllocator,
    answer: Answer,

    pub const Answer = union(Slot) {
        gutter: ui_mesh.GutterBatch.Window,
        status: []const ui_mesh.StatuslineAnswer,
    };

    fn destroy(self: *Entry, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// How many line windows a pane keeps: the current one, the ones either side a
/// scroll just left, and one more for a fold that jumped the layout ahead.
const gutter_windows_per_pane = 4;

pub const Answers = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(*Entry) = .empty,
    pending: std.ArrayList(Request) = .empty,
    stamp: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) Answers {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Answers) void {
        for (self.entries.items) |e| e.destroy(self.gpa);
        self.entries.deinit(self.gpa);
        self.pending.deinit(self.gpa);
    }

    /// Note a question a frame had no answer to. The same question asked
    /// twice before the loop answers is asked once. Dropping one on OOM is
    /// harmless: the next frame asks again.
    pub fn want(self: *Answers, req: Request) void {
        for (self.pending.items) |p| if (p.same(req)) return;
        self.pending.append(self.gpa, req) catch {};
    }

    /// Take every pending question, for the loop to answer. Caller frees.
    pub fn takePending(self: *Answers) ![]Request {
        return self.pending.toOwnedSlice(self.gpa);
    }

    /// The newest status answer `pane` has, whatever it answered.
    pub fn status(self: *const Answers, pane: u32) ?*const Entry {
        var best: ?*const Entry = null;
        for (self.entries.items) |e| {
            if (e.pane != pane or e.answer != .status) continue;
            if (best == null or e.stamp > best.?.stamp) best = e;
        }
        return best;
    }

    /// Every gutter window `pane` has, newest first, into `arena` (frame
    /// scratch). The windows borrow this cache's bytes, which live until the
    /// next `store` — after the frame that reads them.
    pub fn gutterWindows(self: *const Answers, arena: std.mem.Allocator, pane: u32) ![]const ui_mesh.GutterBatch.Window {
        var mine: std.ArrayList(*const Entry) = .empty;
        for (self.entries.items) |e| if (e.pane == pane and e.answer == .gutter) try mine.append(arena, e);
        std.mem.sort(*const Entry, mine.items, {}, struct {
            fn newer(_: void, a: *const Entry, b: *const Entry) bool {
                return a.stamp > b.stamp;
            }
        }.newer);
        const out = try arena.alloc(ui_mesh.GutterBatch.Window, mine.items.len);
        for (mine.items, out) |e, *w| w.* = e.answer.gutter;
        return out;
    }

    /// An empty answer to `req`, for the caller to fill from `entry.arena`
    /// and then `store`.
    pub fn begin(self: *Answers, req: Request) !*Entry {
        const e = try self.gpa.create(Entry);
        e.* = .{
            .pane = req.pane,
            .key = req.key,
            .stamp = 0,
            .arena = .init(self.gpa),
            .answer = switch (req.ask) {
                .gutter => |g| .{ .gutter = .{ .key = req.key, .first = g.first, .answers = &.{} } },
                .status => .{ .status = &.{} },
            },
        };
        return e;
    }

    /// Drop an answer `begin` made that will not be stored.
    pub fn discard(self: *Answers, e: *Entry) void {
        e.destroy(self.gpa);
    }

    /// Keep `e` as the pane's newest answer. A status answer replaces the
    /// pane's last one; a gutter window replaces one for the same lines and
    /// otherwise evicts the pane's oldest past `gutter_windows_per_pane`. On
    /// error `e` is still the caller's (`discard`).
    pub fn store(self: *Answers, e: *Entry) !void {
        try self.entries.ensureUnusedCapacity(self.gpa, 1);
        self.stamp += 1;
        e.stamp = self.stamp;
        var kept: usize = 0;
        var oldest: ?usize = null;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const old = self.entries.items[i];
            const replaces = old.pane == e.pane and @as(Slot, old.answer) == @as(Slot, e.answer) and switch (e.answer) {
                .status => true,
                .gutter => |w| old.answer.gutter.first == w.first,
            };
            if (replaces) {
                old.destroy(self.gpa);
                _ = self.entries.swapRemove(i);
                continue;
            }
            if (old.pane == e.pane and old.answer == .gutter and e.answer == .gutter) {
                kept += 1;
                if (oldest == null or old.stamp < self.entries.items[oldest.?].stamp) oldest = i;
            }
            i += 1;
        }
        if (kept >= gutter_windows_per_pane) {
            self.entries.items[oldest.?].destroy(self.gpa);
            _ = self.entries.swapRemove(oldest.?);
        }
        self.entries.appendAssumeCapacity(e);
    }

    /// Drop the answers of every pane not in `live` — a closed split's cells
    /// have nobody left to show them to.
    pub fn retainPanes(self: *Answers, live: []const u32) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            if (std.mem.indexOfScalar(u32, live, e.pane) == null) {
                e.destroy(self.gpa);
                _ = self.entries.swapRemove(i);
            } else i += 1;
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn gutterReq(pane: u32, key: Key, first: u32) Request {
    return .{ .pane = pane, .entry = undefined, .key = key, .ask = .{ .gutter = .{ .first = first, .count = core.gutter.window, .lines = 1 } } };
}

test "answers: a question asked twice before the loop answers is asked once" {
    var a: Answers = .init(t.allocator);
    defer a.deinit();
    a.want(gutterReq(1, 7, 0));
    a.want(gutterReq(1, 7, 0));
    a.want(gutterReq(1, 7, 256)); // another window: another question
    a.want(gutterReq(2, 7, 0)); // another pane
    const pending = try a.takePending();
    defer t.allocator.free(pending);
    try t.expectEqual(@as(usize, 3), pending.len);
    try t.expectEqual(@as(usize, 0), a.pending.items.len);
}

test "answers: the newest answer wins, a status answer replaces the last, windows are bounded" {
    var a: Answers = .init(t.allocator);
    defer a.deinit();
    const status_req: Request = .{ .pane = 1, .entry = undefined, .key = 1, .ask = .{ .status = .{ .caret = 0, .focused = true } } };
    try a.store(try a.begin(status_req));
    var newer = status_req;
    newer.key = 2;
    try a.store(try a.begin(newer));
    try t.expectEqual(@as(Key, 2), a.status(1).?.key);
    try t.expect(a.status(2) == null);

    for (0..gutter_windows_per_pane + 2) |i| try a.store(try a.begin(gutterReq(1, 9, @intCast(i * core.gutter.window))));
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const windows = try a.gutterWindows(arena.allocator(), 1);
    try t.expectEqual(@as(usize, gutter_windows_per_pane), windows.len);
    try t.expectEqual(@as(usize, (gutter_windows_per_pane + 1) * core.gutter.window), windows[0].first);

    a.retainPanes(&.{2});
    try t.expect(a.status(1) == null);
    try t.expectEqual(@as(usize, 0), (try a.gutterWindows(arena.allocator(), 1)).len);
}
