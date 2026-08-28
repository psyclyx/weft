//! The primary-focus FEED — viewport focus changes as an ordinary
//! subscribable feed (doc/contextual-workspace-architecture.md §7, decided in
//! doc/cwa-config-decisions.md D2).
//!
//! Following logic is a CONSUMER of two ordinary primitives, not a workspace
//! binding language: this feed, plus "present resource R in viewport V" as an
//! operation. The rejected alternative was declarative reactive subject
//! bindings (`subject: follows(focused, lang.symbols)`) evaluated by the
//! workspace — a mini expression language with evaluation order, error
//! semantics, explain integration, and grammar versioning, invented to avoid
//! ten lines of code. Both primitives are needed regardless (statuslines,
//! titles, breadcrumbs, and presence all consume focus state; retarget is
//! just placement), so the split pays nothing new.
//!
//! Every event carries the source viewport's ATTRIBUTES. That is the load-
//! bearing detail: `Companion` below ignores events whose source is not a
//! `focus_source` viewport, so a symbols outline cannot observe its own focus
//! and therefore cannot retarget itself to itself. The bug is not fixed by a
//! guard each follower must remember to write — it is unrepresentable for a
//! follower built on the shipped helper, because the helper filters before
//! the follower ever sees the event.

const std = @import("std");
const Buffers = @import("Buffers.zig");
const viewport = @import("viewport.zig");

pub const Event = struct {
    /// The viewport that gained focus — a `window_layout` pane slot id, kept
    /// as a plain `u32` for the same reason `Head.focused_pane` is (core must
    /// not depend on gfx).
    viewport: u32,
    /// The entry that viewport shows.
    entry: Buffers.Id,
    attrs: viewport.Attrs,

    pub fn eql(self: Event, other: Event) bool {
        return self.viewport == other.viewport and self.entry == other.entry and
            self.attrs.eql(other.attrs);
    }
};

pub const Subscriber = struct {
    context: ?*anyopaque,
    notify: *const fn (?*anyopaque, Event) void,
};

/// A backpressure-free broadcast: subscribers are synchronous observers, and
/// the feed keeps only the LAST event so a late subscriber can be brought
/// current without replaying history it has no way to interpret.
pub const Feed = struct {
    subscribers: std.ArrayList(Subscriber) = .empty,
    last: ?Event = null,

    pub const empty: Feed = .{};

    pub fn deinit(self: *Feed, gpa: std.mem.Allocator) void {
        self.subscribers.deinit(gpa);
        self.* = undefined;
    }

    pub fn subscribe(self: *Feed, gpa: std.mem.Allocator, sub: Subscriber) !void {
        try self.subscribers.append(gpa, sub);
    }

    pub fn unsubscribe(self: *Feed, context: ?*anyopaque) void {
        var i = self.subscribers.items.len;
        while (i > 0) {
            i -= 1;
            if (self.subscribers.items[i].context == context) _ = self.subscribers.orderedRemove(i);
        }
    }

    /// Publish `ev` if it differs from the last one. Idempotent by design:
    /// the layout phase runs every frame and would otherwise re-notify every
    /// follower on every wake.
    pub fn publish(self: *Feed, ev: Event) void {
        if (self.last) |prev| if (prev.eql(ev)) return;
        self.last = ev;
        for (self.subscribers.items) |sub| sub.notify(sub.context, ev);
    }
};

/// The shipped companion helper (D2's "a shipped first-party companion-view
/// helper parameterized by config"): a follower that retargets its own
/// viewport when PRIMARY focus moves.
///
/// It answers the two questions every follower gets wrong by hand — "was that
/// me?" and "was that another companion?" — from the event's attributes,
/// before `retarget` runs. What is left for the consumer is exactly its own
/// business: deriving a subject from the focused entry and presenting it.
pub const Companion = struct {
    /// The viewport this companion occupies.
    viewport: u32,
    context: ?*anyopaque = null,
    /// "Present a resource in my viewport", given the entry that just gained
    /// primary focus. Ordinary operation, ordinary consumer.
    retarget: *const fn (?*anyopaque, Event) void,

    /// Whether `ev` is a primary-focus change this companion should follow.
    pub fn follows(self: *const Companion, ev: Event) bool {
        return ev.attrs.focus_source and ev.viewport != self.viewport;
    }

    pub fn onFocus(self: *const Companion, ev: Event) void {
        if (self.follows(ev)) self.retarget(self.context, ev);
    }

    fn notifyOpaque(raw: ?*anyopaque, ev: Event) void {
        const self: *Companion = @ptrCast(@alignCast(raw.?));
        self.onFocus(ev);
    }

    /// Subscribe this companion to `feed`. The companion address is the
    /// subscription key, so `Feed.unsubscribe(companion)` retires it.
    pub fn subscribe(self: *Companion, gpa: std.mem.Allocator, feed: *Feed) !void {
        try feed.subscribe(gpa, .{ .context = self, .notify = notifyOpaque });
    }
};

const t = std.testing;

/// A docked companion's attributes, spelled out — core names no role.
fn companion(edge: viewport.Edge) viewport.Attrs {
    return .{ .cycles = false, .persistent = true, .dock = edge, .focus_source = false };
}

const Recorder = struct {
    seen: std.ArrayList(Event) = .empty,

    fn record(raw: ?*anyopaque, ev: Event) void {
        const self: *Recorder = @ptrCast(@alignCast(raw.?));
        self.seen.append(t.allocator, ev) catch {};
    }
};

test "focus feed: republishing the same focus notifies nobody twice" {
    const gpa = t.allocator;
    var feed: Feed = .empty;
    defer feed.deinit(gpa);
    var rec: Recorder = .{};
    defer rec.seen.deinit(gpa);
    try feed.subscribe(gpa, .{ .context = &rec, .notify = Recorder.record });

    const a: Event = .{ .viewport = 1, .entry = 7, .attrs = .tiled };
    feed.publish(a);
    feed.publish(a);
    try t.expectEqual(@as(usize, 1), rec.seen.items.len);
    // A different entry in the SAME viewport is still a focus change.
    feed.publish(.{ .viewport = 1, .entry = 8, .attrs = .tiled });
    try t.expectEqual(@as(usize, 2), rec.seen.items.len);
    try t.expect(feed.last.?.eql(.{ .viewport = 1, .entry = 8, .attrs = .tiled }));

    feed.unsubscribe(&rec);
    feed.publish(.{ .viewport = 2, .entry = 9, .attrs = .tiled });
    try t.expectEqual(@as(usize, 2), rec.seen.items.len);
}

test "focus feed: a companion cannot follow itself or another companion" {
    const gpa = t.allocator;
    var feed: Feed = .empty;
    defer feed.deinit(gpa);
    var rec: Recorder = .{};
    defer rec.seen.deinit(gpa);
    var outline: Companion = .{ .viewport = 5, .context = &rec, .retarget = Recorder.record };
    try outline.subscribe(gpa, &feed);

    // Focus landing on an ordinary pane retargets the outline.
    feed.publish(.{ .viewport = 1, .entry = 7, .attrs = .tiled });
    try t.expectEqual(@as(usize, 1), rec.seen.items.len);
    try t.expectEqual(@as(Buffers.Id, 7), rec.seen.items[0].entry);

    // Focus landing on the outline ITSELF is not a primary-focus change: the
    // sidebar bundle is not a `focus_source`, so the retarget never runs and
    // the outline cannot chase its own subject.
    feed.publish(.{ .viewport = 5, .entry = 42, .attrs = companion(.right) });
    try t.expectEqual(@as(usize, 1), rec.seen.items.len);

    // Nor does a DIFFERENT companion's focus retarget it.
    feed.publish(.{ .viewport = 6, .entry = 43, .attrs = companion(.left) });
    try t.expectEqual(@as(usize, 1), rec.seen.items.len);

    // Back to an ordinary pane: following resumes.
    feed.publish(.{ .viewport = 2, .entry = 8, .attrs = .tiled });
    try t.expectEqual(@as(usize, 2), rec.seen.items.len);
    try t.expectEqual(@as(Buffers.Id, 8), rec.seen.items[1].entry);
}
