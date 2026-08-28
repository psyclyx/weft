//! Render-embeds — live regions at anchored extents inside a host entry
//! (doc/contextual-workspace-architecture.md §11.8 depth i).
//!
//! An embed is a marked line holding a durable, text-serializable designation
//! (`@embed weft://<authority>/<kind>/<ref>[?params]`, doc/substrate.md §7)
//! plus view parameters, in the ONE grammar host and guest share
//! (`semantic_model/durable.zig`). The text is the storage form AND the
//! fallback form: an embed that cannot resolve stops overlaying and lets its
//! own bytes show, with a short reason beside them. An embed never errors its
//! host (§15.19), and embedding confers nothing — an ungranted designation
//! degrades to text.
//!
//! **The presentation carve.** A resolved embed renders through the ANNOTATION
//! seam (`layers.zig`): anchored, revision-stamped, display-only decorations
//! that whatever presentation hosts the entry already composites. A nested
//! scene region would mean a second renderer, a second hit-test path, and a
//! second staleness rule over the same anchored spans; the decoration seam
//! already has all three, so v1 borrows them rather than inventing them. The
//! whole presentation hook is `renderInto` — one function, one layer.
//!
//! **Nothing here blocks.** `pump` hands a `Resolver` a generation-checked
//! `Ref` and returns; answers arrive later through `fulfill`/`fail`. Editing
//! the host entry touches no embed state at all — extents ride the document's
//! auto-shifted anchors — and an answer for an embed the text has since
//! deleted, or one the registry has already re-asked, lands nowhere.
//!
//! **Live** is `invalidate`: the designated resource changed, so a resolved
//! embed goes stale (its last window still shows, marked) and the next `pump`
//! re-asks. Feeds that can push do that per change; an fs target re-lists on
//! refresh, which is honest for v1.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Document = @import("Document.zig");
const layers = @import("layers.zig");

/// The grammar is the portable one (`semantic_model/durable.zig`): host and
/// guest read one syntax out of the same bytes, so a note written by a plugin
/// is an embed here and nowhere is there a second parser to keep in step.
pub const durable = @import("weft_semantic").durable;
pub const Designation = durable.Designation;
pub const marker = durable.marker;

/// Rows a window shows when the designation asks for no size, and the ceiling
/// any request is clamped to. A view is bounded by construction (§11.6): no
/// embed can ask a presentation to materialize a whole resource.
pub const default_window = 8;
pub const max_window = 64;

pub const ParseError = error{Malformed};

/// How much of the designated resource this embed asked to see, clamped.
pub fn windowOf(want: Designation) u16 {
    const asked = want.count("lines", default_window);
    return @intCast(std.math.clamp(asked, 1, max_window));
}

/// The designation a bound span holds: an embed line, or the bare designation
/// a caller pinned itself. Both are text that designates; the marker is what
/// makes a LINE one without anybody saying so.
pub fn designationIn(text: []const u8) ParseError!Designation {
    return durable.embedOf(text) orelse durable.parse(text) orelse error.Malformed;
}

/// Where an embed is in its lifecycle. `fallback` is not an error state — it
/// is the storage form showing through, which every other state is an overlay
/// on top of.
pub const State = enum { pending, resolved, stale, fallback, collapsed };

/// Why an embed shows its text instead of a view. Short by design: the reason
/// rides beside a designation the reader can already see.
pub const Reason = enum {
    unknown_target,
    no_grant,
    gone,
    unavailable,

    pub fn note(self: Reason) []const u8 {
        return switch (self) {
            .unknown_target => "unknown target",
            .no_grant => "no grant",
            .gone => "gone",
            .unavailable => "unavailable",
        };
    }
};

/// What each published span means. A presentation styles by role; it never
/// learns which provider resolved the embed.
pub const Role = enum(u32) {
    /// The designation text itself — concealed while a view covers it.
    designation,
    /// Shown at the extent from the first frame, before any answer.
    placeholder,
    /// One row of the bounded view.
    row,
    /// A short reason, staleness mark, or partial-window disclosure.
    note,
};

pub const placeholder_text = "…";

/// A byte range in the host entry, at the current head.
pub const Extent = struct {
    start: usize,
    end: usize,

    pub fn isEmpty(self: Extent) bool {
        return self.end <= self.start;
    }

    fn overlaps(self: Extent, other: Extent) bool {
        return self.start < other.end and other.start < self.end;
    }
};

/// A generation-checked capture of one embed AND of the request it answers. A
/// resolver holds this across an await; a slot that was deleted through,
/// detached, or reused resolves to nothing, so a late answer cannot land on
/// whatever now sits at the offset — and a request the embed has already
/// superseded answers nobody either, however alive its slot still is.
pub const Ref = struct {
    id: u32,
    generation: u32,
    /// 0 = names the embed only, which no answer may land in.
    request: u32 = 0,
};

/// Who turns a designation into rows. `begin` must return promptly — it runs
/// on the presentation's loop — and answer later through `fulfill`/`fail`.
/// It captures the `Ref` and touches nothing else here: the registry is
/// mid-walk, and an answer is a delivery, not a callback.
pub const Resolver = struct {
    ctx: ?*anyopaque = null,
    begin: *const fn (ctx: ?*anyopaque, ref: Ref, want: Designation) void,

    /// A host with no resolver wired: every embed stays at its placeholder,
    /// which is the honest rendering of "nobody has been asked yet".
    pub const idle: Resolver = .{ .begin = ignore };

    fn ignore(_: ?*anyopaque, _: Ref, _: Designation) void {}
};

/// A read-only look at one embed, for hosts and tests. Borrowed until the
/// next mutation.
pub const View = struct {
    state: State,
    reason: ?Reason,
    /// The storage form, exactly as it sits in the host entry.
    designation: []const u8,
    extent: Extent,
    rows: []const []const u8,
    /// The resource has more than the window shows — labelled, never a
    /// truncation that looks like the whole thing (§15 rule 4).
    partial: bool,
};

const Embed = struct {
    doc: *Document,
    start: Document.AnchorHandle,
    end: Document.AnchorHandle,
    text: []u8,
    lines: u16,
    state: State,
    reason: ?Reason = null,
    /// The outstanding request's serial, 0 for none. An answer is applied only
    /// into the request still waiting for it; anything else is superseded and
    /// dropped, including an answer overtaken by an `invalidate` and a re-ask.
    asked: u32 = 0,
    rows: std.ArrayList([]const u8) = .empty,
    partial: bool = false,

    fn clearRows(self: *Embed, gpa: Allocator) void {
        for (self.rows.items) |row| gpa.free(row);
        self.rows.clearRetainingCapacity();
        self.partial = false;
    }

    fn deinit(self: *Embed, gpa: Allocator) void {
        self.clearRows(gpa);
        self.rows.deinit(gpa);
        self.doc.removeAnchor(self.start);
        self.doc.removeAnchor(self.end);
        gpa.free(self.text);
    }

    fn extent(self: *const Embed) Extent {
        return .{
            .start = self.doc.anchorOffset(self.start),
            .end = self.doc.anchorOffset(self.end),
        };
    }
};

/// Every embed of one session, keyed by host entry. Slots are generation
/// stamped, so a `Ref` is only ever good for the embed that minted it.
pub const Embeds = struct {
    resolver: Resolver,
    slots: std.ArrayList(Slot) = .empty,
    /// The next request serial. Monotonic across every embed, so no two asks
    /// ever share a name.
    serial: u32 = 1,

    const Slot = struct {
        generation: u32 = 1,
        embed: ?Embed = null,
    };

    pub fn init(resolver: Resolver) Embeds {
        return .{ .resolver = resolver };
    }

    pub fn deinit(self: *Embeds, gpa: Allocator) void {
        for (self.slots.items) |*slot| if (slot.embed) |*embed| embed.deinit(gpa);
        self.slots.deinit(gpa);
        self.* = .{ .resolver = self.resolver };
    }

    /// Bind `[start, end)` of `doc` as an embed. The extent's own bytes are the
    /// designation; text that does not designate anything is not an embed and
    /// stays plain text.
    pub fn attach(self: *Embeds, gpa: Allocator, doc: *Document, start: usize, end: usize) (Allocator.Error || ParseError)!Ref {
        const text = try readSpan(gpa, doc, start, end);
        errdefer gpa.free(text);
        const want = try designationIn(text);
        const a = try doc.addAnchor(gpa, start, .right);
        errdefer doc.removeAnchor(a);
        const b = try doc.addAnchor(gpa, @max(start, end), .left);
        errdefer doc.removeAnchor(b);
        const embed: Embed = .{
            .doc = doc,
            .start = a,
            .end = b,
            .text = text,
            .lines = windowOf(want),
            .state = .pending,
        };
        for (self.slots.items, 0..) |*slot, index| {
            if (slot.embed != null) continue;
            slot.embed = embed;
            return .{ .id = @intCast(index), .generation = slot.generation };
        }
        try self.slots.append(gpa, .{ .embed = embed });
        return .{ .id = @intCast(self.slots.items.len - 1), .generation = 1 };
    }

    /// Bind every embed line in `doc` that is not bound already. The reader of
    /// the storage form: a note is a note, and the embeds are found in it. A
    /// line is an embed because it is MARKED one, so a sentence that mentions
    /// a designation stays prose.
    pub fn scan(self: *Embeds, gpa: Allocator, doc: *Document) Allocator.Error!usize {
        const text = try readSpan(gpa, doc, 0, doc.text().byteLen());
        defer gpa.free(text);
        var found: usize = 0;
        var at: usize = 0;
        while (at < text.len) {
            const nl = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
            defer at = nl + 1;
            const line = text[at..nl];
            const lead = line.len - std.mem.trimStart(u8, line, " \t").len;
            const body = std.mem.trimEnd(u8, line[lead..], " \t\r");
            if (durable.embedOf(body) == null) continue;
            if (self.boundAt(doc, at + lead)) continue;
            _ = self.attach(gpa, doc, at + lead, at + lead + body.len) catch |err| switch (err) {
                error.Malformed => continue,
                else => |e| return e,
            };
            found += 1;
        }
        return found;
    }

    pub fn detach(self: *Embeds, gpa: Allocator, ref: Ref) void {
        const slot = self.slotOf(ref) orelse return;
        slot.embed.?.deinit(gpa);
        slot.embed = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }

    /// Drop every embed of one host entry (the entry closed).
    pub fn dropDoc(self: *Embeds, gpa: Allocator, doc: *const Document) void {
        for (self.slots.items, 0..) |*slot, index| {
            const embed = if (slot.embed) |*live| live else continue;
            if (embed.doc != doc) continue;
            self.detach(gpa, .{ .id = @intCast(index), .generation = slot.generation });
        }
    }

    pub fn view(self: *const Embeds, ref: Ref) ?View {
        const embed = self.embedOf(ref) orelse return null;
        return .{
            .state = embed.state,
            .reason = embed.reason,
            .designation = embed.text,
            .extent = embed.extent(),
            .rows = embed.rows.items,
            .partial = embed.partial,
        };
    }

    pub fn designation(self: *const Embeds, ref: Ref) ?Designation {
        const embed = self.embedOf(ref) orelse return null;
        return designationIn(embed.text) catch null;
    }

    /// Collapse embeds whose designation the host entry no longer holds. The
    /// text was the embed; deleted through, there is nothing left to render
    /// and nothing left to ask about.
    pub fn sweep(self: *Embeds, gpa: Allocator) void {
        for (self.slots.items) |*slot| {
            const embed = if (slot.embed) |*live| live else continue;
            if (embed.state == .collapsed or !embed.extent().isEmpty()) continue;
            embed.clearRows(gpa);
            embed.state = .collapsed;
            embed.asked = 0;
        }
    }

    /// Ask for what is unresolved and visible. Called from the presentation
    /// loop, never from an edit: `visible` null means every extent, and a
    /// bounded window resolves only what a reader has reached (§11.6).
    pub fn pump(self: *Embeds, gpa: Allocator, visible: ?Extent) void {
        self.sweep(gpa);
        for (self.slots.items, 0..) |*slot, index| {
            const embed = if (slot.embed) |*live| live else continue;
            if (embed.asked != 0 or (embed.state != .pending and embed.state != .stale)) continue;
            if (visible) |window| if (!embed.extent().overlaps(window)) continue;
            const want = designationIn(embed.text) catch {
                embed.state = .fallback;
                embed.reason = .unknown_target;
                continue;
            };
            embed.asked = self.serial;
            self.serial +%= 1;
            if (self.serial == 0) self.serial = 1;
            self.resolver.begin(
                self.resolver.ctx,
                .{ .id = @intCast(index), .generation = slot.generation, .request = embed.asked },
                want,
            );
        }
    }

    /// Deliver a bounded window. Rows past the embed's own limit are dropped
    /// and disclosed as partial, never shown as the whole resource.
    pub fn fulfill(self: *Embeds, gpa: Allocator, ref: Ref, rows: []const []const u8) Allocator.Error!void {
        const embed = self.awaitingOf(ref) orelse return;
        embed.clearRows(gpa);
        const shown = @min(rows.len, embed.lines);
        try embed.rows.ensureTotalCapacity(gpa, shown);
        for (rows[0..shown]) |row| embed.rows.appendAssumeCapacity(try gpa.dupe(u8, row));
        embed.partial = rows.len > shown;
        embed.state = .resolved;
        embed.reason = null;
        embed.asked = 0;
    }

    /// The designation did not resolve. The embed keeps its text — that is the
    /// fallback — and carries the reason beside it. The host is untouched.
    pub fn fail(self: *Embeds, gpa: Allocator, ref: Ref, reason: Reason) void {
        const embed = self.awaitingOf(ref) orelse return;
        embed.clearRows(gpa);
        embed.state = .fallback;
        embed.reason = reason;
        embed.asked = 0;
    }

    /// The designated resource changed: every embed of it re-asks on the next
    /// pump. A resolved one keeps showing its last window, marked stale, so a
    /// live update never blinks through empty.
    pub fn invalidate(self: *Embeds, gpa: Allocator, changed: Designation) void {
        for (self.slots.items) |*slot| {
            const embed = if (slot.embed) |*live| live else continue;
            if (embed.state == .collapsed) continue;
            const want = designationIn(embed.text) catch continue;
            if (!want.designates(changed)) continue;
            // An answer already in flight described the resource before this
            // change: drop it by clearing the request it would land in.
            embed.asked = 0;
            switch (embed.state) {
                .resolved, .stale => embed.state = .stale,
                else => {
                    embed.clearRows(gpa);
                    embed.state = .pending;
                    embed.reason = null;
                },
            }
        }
    }

    /// The whole presentation hook: publish one round of `doc`'s embeds into
    /// an annotation layer claimed for it. Placeholder, window rows, staleness
    /// and reasons are all anchored decorations — the presentation composites
    /// them like any other feed and learns nothing about embedding.
    pub fn renderInto(self: *const Embeds, gpa: Allocator, doc: *const Document, layer: *layers.Layer) Allocator.Error!void {
        layer.begin(gpa);
        for (self.slots.items) |*slot| {
            const embed = if (slot.embed) |*live| live else continue;
            if (embed.doc != doc or embed.state == .collapsed) continue;
            const at = embed.extent();
            if (at.isEmpty()) continue;
            // The designation is concealed only while a view covers it; every
            // other state shows the storage form, which is the fallback form.
            const covered = embed.state == .resolved or embed.state == .stale;
            try layer.appendSpan(gpa, .{
                .start = at.start,
                .end = at.end,
                .kind = @intFromEnum(Role.designation),
                .message = "",
                .face = .{ .invisible = covered },
            });
            if (embed.state == .pending) try layer.appendSpan(gpa, .{
                .start = at.end,
                .end = at.end,
                .kind = @intFromEnum(Role.placeholder),
                .message = placeholder_text,
                .placement = .virtual_after,
            });
            for (embed.rows.items) |row| try layer.appendSpan(gpa, .{
                .start = at.end,
                .end = at.end,
                .kind = @intFromEnum(Role.row),
                .message = row,
                .placement = .virtual_after,
            });
            const note: ?[]const u8 = if (embed.reason) |reason|
                reason.note()
            else if (embed.state == .stale)
                "stale"
            else if (embed.partial)
                "partial"
            else
                null;
            if (note) |message| try layer.appendSpan(gpa, .{
                .start = at.end,
                .end = at.end,
                .kind = @intFromEnum(Role.note),
                .message = message,
                .placement = .eol,
            });
        }
    }

    fn slotOf(self: *Embeds, ref: Ref) ?*Slot {
        if (ref.id >= self.slots.items.len) return null;
        const slot = &self.slots.items[ref.id];
        if (slot.generation != ref.generation or slot.embed == null) return null;
        return slot;
    }

    fn embedOf(self: *const Embeds, ref: Ref) ?*const Embed {
        if (ref.id >= self.slots.items.len) return null;
        const slot = &self.slots.items[ref.id];
        if (slot.generation != ref.generation) return null;
        return if (slot.embed) |*embed| embed else null;
    }

    /// The embed an answer may land in: live, still holding its extent, and
    /// still waiting for THIS request. An answer overtaken by an invalidate
    /// and its re-ask names a request nobody waits for any more.
    fn awaitingOf(self: *Embeds, ref: Ref) ?*Embed {
        const slot = self.slotOf(ref) orelse return null;
        const embed = &slot.embed.?;
        if (ref.request == 0 or embed.asked != ref.request) return null;
        if (embed.state == .collapsed or embed.extent().isEmpty()) return null;
        return embed;
    }

    fn boundAt(self: *const Embeds, doc: *const Document, offset: usize) bool {
        for (self.slots.items) |*slot| {
            const embed = if (slot.embed) |*live| live else continue;
            if (embed.doc == doc and embed.extent().start == offset) return true;
        }
        return false;
    }
};

fn readSpan(gpa: Allocator, doc: *const Document, start: usize, end: usize) Allocator.Error![]u8 {
    const rope = doc.text();
    const len = rope.byteLen();
    const a = @min(start, len);
    const b = @min(@max(a, end), len);
    const buf = try gpa.alloc(u8, b - a);
    errdefer gpa.free(buf);
    if (buf.len > 0) {
        var sr = rope.streamReader(.{ .start = a, .end = b }, &.{});
        sr.interface.readSliceAll(buf) catch unreachable; // in bounds
    }
    return buf;
}

// ── tests ───────────────────────────────────────────────────────────

const t = std.testing;

/// A fixture resource: records what it was asked for, answers when the test
/// says so. It holds only `Ref`s across the await, which is the whole
/// discipline — nothing it captured can name the wrong embed later.
const Fixture = struct {
    asked: std.ArrayList(Ref) = .empty,
    calls: usize = 0,

    fn resolver(self: *Fixture) Resolver {
        return .{ .ctx = self, .begin = begin };
    }

    fn begin(ctx: ?*anyopaque, ref: Ref, _: Designation) void {
        const self: *Fixture = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.asked.append(t.allocator, ref) catch {};
    }

    fn take(self: *Fixture) Ref {
        return self.asked.orderedRemove(0);
    }

    fn deinit(self: *Fixture) void {
        self.asked.deinit(t.allocator);
    }
};

fn noteWith(gpa: Allocator, text: []const u8) !Document {
    var doc = try Document.init(gpa, "user");
    errdefer doc.deinit(gpa);
    try doc.insert(gpa, 0, text);
    return doc;
}

fn spanRoles(layer: *const layers.Layer, role: Role) usize {
    var n: usize = 0;
    for (0..layer.spanCount()) |i| {
        if (layer.resolvedSpan(i).kind == @intFromEnum(role)) n += 1;
    }
    return n;
}

fn firstMessage(layer: *const layers.Layer, role: Role) ?[]const u8 {
    for (0..layer.spanCount()) |i| {
        const span = layer.resolvedSpan(i);
        if (span.kind == @intFromEnum(role)) return span.message;
    }
    return null;
}

test "embed: the bound text is the portable grammar, and the window it asks for is bounded" {
    // One grammar: what a guest writes into a note is what the host binds.
    const plain = try designationIn("@embed weft://here/dir/src/core");
    try t.expect(plain.authority == .here);
    try t.expect(plain.kind == .directory);
    try t.expectEqualStrings("src/core", plain.ref);
    try t.expectEqual(@as(u16, default_window), windowOf(plain));

    const windowed = try designationIn("@embed weft://ab12cd/commit/9f3a?lines=3");
    try t.expect(windowed.authority.eql(.{ .peer = "ab12cd" }));
    try t.expectEqual(@as(u16, 3), windowOf(windowed));
    // A view parameter is a request about presentation, never identity.
    try t.expect(windowed.designates(try designationIn("weft://ab12cd/commit/9f3a?lines=9")));
    try t.expect(!windowed.designates(try designationIn("weft://here/commit/9f3a")));
    // Unknown parameters are ignored; the designation still resolves.
    try t.expectEqual(@as(u16, 2), windowOf(try designationIn("weft://here/file/a?as=table&lines=2")));
    // A window is bounded whatever the text asks for, both ways.
    try t.expectEqual(@as(u16, max_window), windowOf(try designationIn("weft://here/file/a?lines=9000")));
    try t.expectEqual(@as(u16, 1), windowOf(try designationIn("weft://here/file/a?lines=0")));

    for ([_][]const u8{ "https://example/x", "weft://here", "weft://here/file/", "weft:///file/a", "@embed", "@embed weft://here/file/a and prose" }) |bad| {
        try t.expectError(error.Malformed, designationIn(bad));
    }
}

test "embed: placeholder, resolved window, live staleness, then fallback" {
    const gpa = t.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit();
    var doc = try noteWith(gpa, "notes:\n@embed weft://here/dir/src?lines=2\ntail\n");
    defer doc.deinit(gpa);
    var store: layers.Layers = .empty;
    defer store.deinit(gpa);
    const layer = try store.claimAnnotation(gpa, &doc, "embeds", "embed");

    var embeds: Embeds = .init(fixture.resolver());
    defer embeds.deinit(gpa);
    try t.expectEqual(@as(usize, 1), try embeds.scan(gpa, &doc));
    try t.expectEqual(@as(usize, 0), try embeds.scan(gpa, &doc)); // already bound
    const ref = fixtureRef: {
        embeds.pump(gpa, null);
        break :fixtureRef fixture.take();
    };

    // Placeholder from the first frame, before anybody has answered.
    try t.expectEqual(State.pending, embeds.view(ref).?.state);
    try embeds.renderInto(gpa, &doc, layer);
    try t.expectEqual(@as(usize, 1), spanRoles(layer, .placeholder));
    try t.expectEqual(@as(usize, 0), spanRoles(layer, .row));

    // Resolved: a bounded view of the designated resource, and the
    // designation text is covered by it.
    try embeds.fulfill(gpa, ref, &.{ "core.zig", "layers.zig", "embed.zig" });
    const resolved = embeds.view(ref).?;
    try t.expectEqual(State.resolved, resolved.state);
    try t.expectEqual(@as(usize, 2), resolved.rows.len); // ?lines=2
    try t.expect(resolved.partial); // never a truncation that looks whole
    try embeds.renderInto(gpa, &doc, layer);
    try t.expectEqual(@as(usize, 2), spanRoles(layer, .row));
    try t.expectEqual(@as(usize, 0), spanRoles(layer, .placeholder));
    try t.expectEqualStrings("partial", firstMessage(layer, .note).?);
    try t.expect(layer.resolvedSpan(0).face.invisible);

    // Live: the directory changed. The last window still shows, marked, and
    // the next pump re-asks.
    embeds.invalidate(gpa, try designationIn("weft://here/dir/src"));
    try t.expectEqual(State.stale, embeds.view(ref).?.state);
    try t.expectEqual(@as(usize, 2), embeds.view(ref).?.rows.len);
    try embeds.renderInto(gpa, &doc, layer);
    try t.expectEqualStrings("stale", firstMessage(layer, .note).?);
    embeds.pump(gpa, null);
    try t.expectEqual(@as(usize, 2), fixture.calls);

    // Unresolvable: the storage form is the fallback form, plus a reason.
    embeds.fail(gpa, fixture.take(), .gone);
    const fallen = embeds.view(ref).?;
    try t.expectEqual(State.fallback, fallen.state);
    try t.expectEqual(@as(usize, 0), fallen.rows.len);
    try t.expectEqualStrings("@embed weft://here/dir/src?lines=2", fallen.designation);
    try embeds.renderInto(gpa, &doc, layer);
    try t.expectEqualStrings("gone", firstMessage(layer, .note).?);
    try t.expect(!layer.resolvedSpan(0).face.invisible);

    // The host entry never lost a byte to any of it.
    const text = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(text);
    try t.expectEqualStrings("notes:\n@embed weft://here/dir/src?lines=2\ntail\n", text);
}

test "embed: typing during a pending resolution neither blocks nor misplaces" {
    const gpa = t.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit();
    var doc = try noteWith(gpa, "@embed weft://here/file/README.md\n");
    defer doc.deinit(gpa);
    var store: layers.Layers = .empty;
    defer store.deinit(gpa);
    const layer = try store.claimAnnotation(gpa, &doc, "embeds", "embed");

    var embeds: Embeds = .init(fixture.resolver());
    defer embeds.deinit(gpa);
    const ref = try embeds.attach(gpa, &doc, 0, 33);
    embeds.pump(gpa, null);
    try t.expectEqual(@as(usize, 1), fixture.calls);
    const asked = fixture.take();

    // Type around the pending embed: no resolver call, no state change, and
    // the extent rides the document's anchors.
    for ("hold that thought: ") |c| try doc.insert(gpa, 0, &.{c});
    try doc.insert(gpa, doc.text().byteLen(), "and more\n");
    try t.expectEqual(@as(usize, 1), fixture.calls);
    try t.expectEqual(State.pending, embeds.view(ref).?.state);
    try t.expectEqual(Extent{ .start = 19, .end = 52 }, embeds.view(ref).?.extent);

    // The answer to the request made before all that typing still lands on
    // the designation's own bytes.
    try embeds.fulfill(gpa, asked, &.{"# weft"});
    try embeds.renderInto(gpa, &doc, layer);
    try t.expectEqual(@as(usize, 1), spanRoles(layer, .row));
    try t.expectEqual(@as(usize, 52), layer.resolvedSpan(1).start);
}

test "embed: deleted through collapses to text, and late answers land nowhere" {
    const gpa = t.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit();
    var doc = try noteWith(gpa, "@embed weft://here/dir/src\nprose about weft://here/dir/src\n");
    defer doc.deinit(gpa);
    var store: layers.Layers = .empty;
    defer store.deinit(gpa);
    const layer = try store.claimAnnotation(gpa, &doc, "embeds", "embed");

    var embeds: Embeds = .init(fixture.resolver());
    defer embeds.deinit(gpa);
    // The marked line is an embed; the sentence that mentions one is prose.
    try t.expectEqual(@as(usize, 1), try embeds.scan(gpa, &doc));
    embeds.pump(gpa, null);
    const ref = fixture.take();
    try embeds.fulfill(gpa, ref, &.{"core.zig"});
    try embeds.renderInto(gpa, &doc, layer);
    try t.expectEqual(@as(usize, 1), spanRoles(layer, .row));

    // The reader deletes the designation. The embed was its text: with the
    // text gone there is nothing to render and nothing to ask about.
    try doc.delete(gpa, .{ .start = 0, .end = 26 });
    embeds.pump(gpa, null);
    try t.expectEqual(State.collapsed, embeds.view(ref).?.state);
    try t.expectEqual(@as(usize, 1), fixture.calls);
    try embeds.renderInto(gpa, &doc, layer);
    try t.expectEqual(@as(usize, 0), layer.spanCount());

    // An answer for a collapsed embed is dropped, not applied to whatever
    // now sits at the offset.
    try embeds.fulfill(gpa, ref, &.{"stale listing"});
    embeds.fail(gpa, ref, .gone);
    try t.expectEqual(State.collapsed, embeds.view(ref).?.state);
    try t.expectEqual(@as(usize, 0), embeds.view(ref).?.rows.len);

    // A detached slot answers nobody: the ref no longer names an embed.
    embeds.detach(gpa, ref);
    try t.expect(embeds.view(ref) == null);
    try embeds.fulfill(gpa, ref, &.{"gone"});

    // Re-typing the designation binds a fresh embed with its own identity.
    try doc.insert(gpa, 0, "@embed weft://here/dir/src");
    try t.expectEqual(@as(usize, 1), try embeds.scan(gpa, &doc));
    embeds.pump(gpa, null);
    const again = fixture.take();
    try t.expect(!std.meta.eql(again, ref));
    try t.expectEqual(State.pending, embeds.view(again).?.state);
}

test "embed: an ungranted designation degrades to text and never errors its host" {
    const gpa = t.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit();
    var doc = try noteWith(gpa, "@embed weft://alice/file/secret.md\n@embed weft://here/file/open.md\n");
    defer doc.deinit(gpa);
    var store: layers.Layers = .empty;
    defer store.deinit(gpa);
    const layer = try store.claimAnnotation(gpa, &doc, "embeds", "embed");

    var embeds: Embeds = .init(fixture.resolver());
    defer embeds.deinit(gpa);
    try t.expectEqual(@as(usize, 2), try embeds.scan(gpa, &doc));
    embeds.pump(gpa, null);
    const secret = fixture.take();
    const open = fixture.take();

    // Embedding confers nothing: the peer's file is refused, the local one
    // resolves, and neither outcome is the host's problem.
    embeds.fail(gpa, secret, .no_grant);
    try embeds.fulfill(gpa, open, &.{"# open"});
    try embeds.renderInto(gpa, &doc, layer);
    try t.expectEqualStrings("no grant", firstMessage(layer, .note).?);
    try t.expectEqual(@as(usize, 1), spanRoles(layer, .row));
    try t.expectEqualStrings("@embed weft://alice/file/secret.md", embeds.view(secret).?.designation);
}

test "embed: only the outstanding request is answered, and only what is visible is asked" {
    const gpa = t.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit();
    var doc = try noteWith(gpa, "@embed weft://here/dir/a\n@embed weft://here/dir/b\n");
    defer doc.deinit(gpa);

    var embeds: Embeds = .init(fixture.resolver());
    defer embeds.deinit(gpa);
    _ = try embeds.scan(gpa, &doc);

    // Windowed: an extent the reader has not reached is not resolved.
    embeds.pump(gpa, .{ .start = 0, .end = 24 });
    try t.expectEqual(@as(usize, 1), fixture.calls);
    const first = fixture.take();
    try embeds.fulfill(gpa, first, &.{"a/"});

    // A change while an answer is in flight supersedes it: the stale answer
    // is dropped and the re-ask stands.
    embeds.invalidate(gpa, try designationIn("weft://here/dir/a"));
    embeds.pump(gpa, .{ .start = 0, .end = 24 });
    try t.expectEqual(@as(usize, 2), fixture.calls);
    const reask = fixture.take();
    embeds.invalidate(gpa, try designationIn("weft://here/dir/a"));
    try embeds.fulfill(gpa, reask, &.{"superseded"});
    try t.expectEqual(State.stale, embeds.view(first).?.state);
    try t.expectEqualStrings("a/", embeds.view(first).?.rows[0]);

    // The second embed is asked once the window reaches it; the first one's
    // outstanding re-ask waits until the window comes back to it.
    embeds.pump(gpa, .{ .start = 25, .end = 49 });
    try t.expectEqual(@as(usize, 3), fixture.calls);
    embeds.pump(gpa, null);
    try t.expectEqual(@as(usize, 4), fixture.calls);
}

test "embed: an answer overtaken by a re-ask loses to the answer that was re-asked for" {
    const gpa = t.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit();
    var doc = try noteWith(gpa, "@embed weft://here/dir/src\n");
    defer doc.deinit(gpa);

    var embeds: Embeds = .init(fixture.resolver());
    defer embeds.deinit(gpa);
    _ = try embeds.scan(gpa, &doc);
    embeds.pump(gpa, null);
    const in_flight = fixture.take();

    // The resource changes while the first answer is still travelling, and
    // the next pump re-asks — so two answers are now owed to one embed.
    embeds.invalidate(gpa, try designationIn("weft://here/dir/src"));
    embeds.pump(gpa, null);
    const current = fixture.take();
    try t.expect(in_flight.request != current.request);

    // The overtaken answer describes the world before the change: it names a
    // request nobody waits for, so it lands nowhere, and the answer that WAS
    // asked for still lands after it.
    try embeds.fulfill(gpa, in_flight, &.{"before the change"});
    try t.expectEqual(State.pending, embeds.view(current).?.state);
    try embeds.fulfill(gpa, current, &.{"after the change"});
    try t.expectEqual(State.resolved, embeds.view(current).?.state);
    try t.expectEqualStrings("after the change", embeds.view(current).?.rows[0]);
}

test "embed: a host with no resolver holds its placeholders" {
    const gpa = t.allocator;
    var doc = try noteWith(gpa, "@embed weft://here/dir/src\n");
    defer doc.deinit(gpa);
    var store: layers.Layers = .empty;
    defer store.deinit(gpa);
    const layer = try store.claimAnnotation(gpa, &doc, "embeds", "embed");

    var embeds: Embeds = .init(.idle);
    defer embeds.deinit(gpa);
    _ = try embeds.scan(gpa, &doc);
    embeds.pump(gpa, null);
    try embeds.renderInto(gpa, &doc, layer);
    try t.expectEqual(@as(usize, 1), spanRoles(layer, .placeholder));
    try t.expectEqualStrings(placeholder_text, firstMessage(layer, .placeholder).?);
}

test {
    t.refAllDecls(@This());
}
