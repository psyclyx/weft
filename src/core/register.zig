//! The kill/register service — the session-wide store of the last yanked text,
//! its linewise flag, and (the point) the FACTS of any subbuffers that
//! overlapped the yanked range, ferried at relative offsets.
//!
//! Why this is core, not a guest's private buffer: an id bound to bytes CANNOT
//! ride copied content. A yank reads raw bytes; a paste is a fresh insert whose
//! bytes get new CRDT identities; anchors (and the subbuffers/layer-spans built
//! on them) are keyed by POSITION, not tagged onto characters (`subbuffer.zig`,
//! `AnchorSet`), so none of them travel with copied text. The ONLY thing that
//! spans a cut-in-buffer-A → paste-in-buffer-B is the register. So the register
//! must snapshot the id-payload on yank and re-stamp it on paste — which is
//! exactly what makes a files row's hidden identity survive `dd`→`p` (a MOVE)
//! while a re-typed or raw-text-pasted line acquires none (a CREATE). Owned by
//! core so every editor (vim/helix/modeless) shares ONE register and the
//! identity-ferry is editor-agnostic (vim's private `reg_buf`, which helix
//! free-rode by name, left a helix-only build with no register at all).
//!
//! Mechanism only: it stores bytes + payloads and answers "re-stamp these ids
//! over text just inserted at `base`". WHO yanks/pastes (the editor) and WHAT
//! carries an id (a projection's per-row subbuffer) is policy elsewhere.

const std = @import("std");
const Allocator = std.mem.Allocator;

const subbuffer = @import("subbuffer.zig");
const Document = @import("Document.zig");

pub const Register = @This();

pub const Range = Document.Range;

/// One snapshotted fact (name→value), both owned by the register.
pub const Fact = struct { name: []u8, value: []u8 };

/// The facts of one subbuffer that overlapped the yanked range, recorded at its
/// offset relative to the range start (and clipped to it) so a paste can
/// re-place the identity over the corresponding bytes.
pub const Payload = struct {
    offset: usize,
    len: usize,
    facts: []Fact,
};

/// Explicit register slots. Slot zero is unnamed; 1..26 are `a`..`z`; 27
/// is `/`, the last search pattern, which every grammar's search writes and
/// every grammar can read (helix's `/` sets it, vim's `"/p` pastes it).
/// Named yanks also update unnamed, while every read/restamp names its slot
/// explicitly so a prefix cannot leak through ambient state.
pub const Bank = struct {
    pub const search: u8 = 27;
    pub const slot_count = 28;

    slots: [slot_count]Register = @splat(.empty),

    pub fn deinit(self: *Bank, gpa: Allocator) void {
        for (&self.slots) |*slot| slot.deinit(gpa);
        self.* = .{};
    }

    pub fn get(self: *Bank, name: u8) ?*Register {
        if (name >= slot_count) return null;
        return &self.slots[name];
    }

    /// Put `bytes` in slot `name` as one charwise value with no ferried
    /// identity — text that was typed, not yanked (a search pattern). Unlike
    /// a yank it leaves unnamed alone: setting the search register is not a
    /// copy, and must not replace what `p` pastes.
    pub fn set(self: *Bank, gpa: Allocator, name: u8, bytes: []const u8) !void {
        const selected = self.get(name) orelse return error.InvalidRegister;
        var next = Register.empty;
        errdefer next.deinit(gpa);
        try next.text.appendSlice(gpa, bytes);
        try next.spans.append(gpa, .{ .start = 0, .end = bytes.len });
        selected.deinit(gpa);
        selected.* = next;
    }

    pub fn yank(self: *Bank, gpa: Allocator, name: u8, subs: ?*const subbuffer.SubBuffers, doc: *const Document, range: Range, bytes: []const u8, linewise: bool) !void {
        return self.yankEach(gpa, name, subs, doc, &.{.{ .range = range, .bytes = bytes }}, linewise);
    }

    /// Yank one value per selection into slot `name` (see `Register.yankEach`).
    pub fn yankEach(self: *Bank, gpa: Allocator, name: u8, subs: ?*const subbuffer.SubBuffers, doc: *const Document, pieces: []const Piece, linewise: bool) !void {
        const selected = self.get(name) orelse return error.InvalidRegister;
        // Prepare a complete independent snapshot for each destination before
        // swapping either one. This keeps named+unnamed capture atomic under
        // allocator failure.
        var next_selected = Register.empty;
        errdefer next_selected.deinit(gpa);
        try next_selected.yankEach(gpa, subs, doc, pieces, linewise);
        var next_unnamed = Register.empty;
        if (name != 0) {
            errdefer next_unnamed.deinit(gpa);
            try next_unnamed.yankEach(gpa, subs, doc, pieces, linewise);
        }
        selected.deinit(gpa);
        selected.* = next_selected;
        next_selected = .empty;
        if (name != 0) {
            self.slots[0].deinit(gpa);
            self.slots[0] = next_unnamed;
            next_unnamed = .empty;
        }
    }
};

/// One captured value: the range it came from and its live bytes.
pub const Piece = struct { range: Range, bytes: []const u8 };

/// Every value's bytes, JOINED: the values in order, a `\n` between two when
/// the earlier does not already end in one. The joined text is the register's
/// only byte storage — a single value is the whole text, so a single-cursor
/// yank stores and reads exactly what it always did.
text: std.ArrayList(u8) = .empty,
/// Each value's span within `text`, one per selection that yanked, in
/// selection (document) order. Empty until the first yank.
spans: std.ArrayList(Range) = .empty,
linewise: bool = false,
/// Ferried identities, at offsets into the JOINED `text`.
payloads: std.ArrayList(Payload) = .empty,

pub const empty: Register = .{};

pub fn deinit(self: *Register, gpa: Allocator) void {
    self.text.deinit(gpa);
    self.spans.deinit(gpa);
    self.clearPayloads(gpa);
    self.payloads.deinit(gpa);
    self.* = .{};
}

/// How many values the register holds (one per yanking selection).
pub fn valueCount(self: *const Register) usize {
    return self.spans.items.len;
}

/// THE PASTE-DISTRIBUTION RULE — what selection `index` of `count` pastes.
/// When the register holds exactly `count` values, each selection gets its own
/// (selection i ← value i, in document order: helix's rule, so yanking three
/// words with three carets and pasting with three carets moves each word to
/// its own caret). Otherwise every selection gets the JOINED text — all the
/// values, newline-separated — so nothing yanked is silently dropped (one
/// caret pasting a three-selection yank gets all three; three carets pasting
/// a one-value yank each get that value, which is the joined text of one).
pub fn pasteSpan(self: *const Register, index: usize, count: usize) Range {
    if (count == self.spans.items.len and index < count) return self.spans.items[index];
    return .{ .start = 0, .end = self.text.items.len };
}

/// The bytes `pasteSpan(index, count)` names.
pub fn pasteValue(self: *const Register, index: usize, count: usize) []const u8 {
    const s = self.pasteSpan(index, count);
    return self.text.items[s.start..s.end];
}

fn clearPayloads(self: *Register, gpa: Allocator) void {
    for (self.payloads.items) |pl| freePayload(gpa, pl);
    self.payloads.clearRetainingCapacity();
}

fn freePayload(gpa: Allocator, pl: Payload) void {
    for (pl.facts) |f| {
        gpa.free(f.name);
        gpa.free(f.value);
    }
    gpa.free(pl.facts);
}

/// Read `text()` (bytes valid until the next `yank`).
pub fn slice(self: *const Register) []const u8 {
    return self.text.items;
}

/// Capture `bytes` as the register content and snapshot the facts of every
/// subbuffer on `doc` that overlaps `range` (whose live bytes ARE `bytes`).
/// Called at yank time — while the source subbuffers still span their names,
/// BEFORE any delete collapses their anchors. Text-only sources (no subbuffer
/// service, or a range with no id-spans) capture bytes and zero payloads, so a
/// later paste re-stamps nothing → a CREATE, structurally.
pub fn yank(
    self: *Register,
    gpa: Allocator,
    subs: ?*const subbuffer.SubBuffers,
    doc: *const Document,
    range: Range,
    bytes: []const u8,
    linewise: bool,
) Allocator.Error!void {
    return self.yankEach(gpa, subs, doc, &.{.{ .range = range, .bytes = bytes }}, linewise);
}

/// Capture one value per selection: `pieces` in selection order, each the
/// live bytes of its range. Joined into `text` (see its doc) with each value's
/// span recorded; each piece's subbuffer facts are snapshotted at offsets into
/// the joined text. One piece is exactly `yank`.
pub fn yankEach(
    self: *Register,
    gpa: Allocator,
    subs: ?*const subbuffer.SubBuffers,
    doc: *const Document,
    pieces: []const Piece,
    linewise: bool,
) Allocator.Error!void {
    self.text.clearRetainingCapacity();
    self.spans.clearRetainingCapacity();
    self.linewise = linewise;
    self.clearPayloads(gpa);
    for (pieces) |piece| {
        const t_items = self.text.items;
        if (t_items.len > 0 and t_items[t_items.len - 1] != '\n') try self.text.append(gpa, '\n');
        const base = self.text.items.len;
        try self.text.appendSlice(gpa, piece.bytes);
        try self.spans.append(gpa, .{ .start = base, .end = self.text.items.len });
        const sub_service = subs orelse continue;
        const range = piece.range;
        for (sub_service.list.items) |s| {
            if (s.doc != doc) continue;
            const r = s.resolve();
            // Half-open overlap with [range.start, range.end); skip the disjoint.
            if (r.end <= range.start or r.start >= range.end) continue;
            const st = @max(r.start, range.start);
            const en = @min(r.end, range.end);
            try self.snapshot(gpa, s, base + st - range.start, en - st);
        }
    }
}

/// Snapshot one subbuffer's facts into a payload at `[offset, offset+len)`.
fn snapshot(self: *Register, gpa: Allocator, s: *const subbuffer.SubBuffer, offset: usize, len: usize) Allocator.Error!void {
    var facts: std.ArrayList(Fact) = .empty;
    errdefer {
        for (facts.items) |f| {
            gpa.free(f.name);
            gpa.free(f.value);
        }
        facts.deinit(gpa);
    }
    var it = s.facts.iterator();
    while (it.next()) |e| {
        const name = try gpa.dupe(u8, e.key_ptr.*);
        errdefer gpa.free(name);
        const value = try gpa.dupe(u8, e.value_ptr.*);
        errdefer gpa.free(value);
        try facts.append(gpa, .{ .name = name, .value = value });
    }
    const owned = try facts.toOwnedSlice(gpa);
    errdefer gpa.free(owned);
    try self.payloads.append(gpa, .{ .offset = offset, .len = len, .facts = owned });
}

/// Re-claim a subbuffer for each ferried payload over text ALREADY inserted at
/// `base` on `doc`, restoring its facts. The editor owns positioning (it did
/// the insert); this only re-stamps identity, so `dd`→`p` moves the id and a
/// plain insert (no payloads) creates nothing. Best-effort per payload — a
/// failed claim drops that one id rather than the whole paste.
pub fn restamp(self: *const Register, gpa: Allocator, subs: *subbuffer.SubBuffers, doc: *Document, base: usize) void {
    self.restampSpan(gpa, subs, doc, base, .{ .start = 0, .end = self.text.items.len });
}

/// `restamp` for the value selection `index` of `count` pasted
/// (`pasteValue(index, count)`, inserted at `base`): only the identities that
/// ride that value's bytes are re-claimed.
pub fn restampValue(self: *const Register, gpa: Allocator, subs: *subbuffer.SubBuffers, doc: *Document, base: usize, index: usize, count: usize) void {
    self.restampSpan(gpa, subs, doc, base, self.pasteSpan(index, count));
}

fn restampSpan(self: *const Register, gpa: Allocator, subs: *subbuffer.SubBuffers, doc: *Document, base: usize, span: Range) void {
    for (self.payloads.items) |pl| {
        if (pl.offset < span.start or pl.offset + pl.len > span.end) continue;
        const at = base + pl.offset - span.start;
        const sub = subs.claim(gpa, doc, .{ .start = at, .end = at + pl.len }) catch continue;
        for (pl.facts) |f| sub.putFact(gpa, f.name, f.value) catch {};
    }
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "register: an id-span ferries across yank→restamp; plain text carries none" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    //             0         1
    //             012345678901
    try doc.insert(gpa, 0, "foo.zig\nbar\n");
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);

    // A files row: the name "foo.zig" (0..7) carries a hidden id.
    const row = try subs.claim(gpa, &doc, .{ .start = 0, .end = 7 });
    try row.putFact(gpa, "id", "7");
    try row.putFact(gpa, "kind", "file");

    var reg: Register = .empty;
    defer reg.deinit(gpa);

    // Yank the first line linewise (as `yy`/`dd` would) — snapshots the id.
    try reg.yank(gpa, &subs, &doc, .{ .start = 0, .end = 7 }, "foo.zig", true);
    try t.expectEqualStrings("foo.zig", reg.slice());
    try t.expect(reg.linewise);
    try t.expectEqual(@as(usize, 1), reg.payloads.items.len);
    try t.expectEqual(@as(usize, 0), reg.payloads.items[0].offset);
    try t.expectEqual(@as(usize, 7), reg.payloads.items[0].len);

    // Simulate `dd` (delete the line + its newline) then `p` in another spot:
    // the editor inserts the register text; restamp re-stamps the id over it.
    try doc.delete(gpa, .{ .start = 0, .end = 8 }); // "foo.zig\n" gone → "bar\n"
    try doc.insert(gpa, 4, "foo.zig"); // paste after "bar\n" → "bar\nfoo.zig"
    reg.restamp(gpa, &subs, &doc, 4);

    // The pasted name carries the ferried identity — that's a MOVE, not a
    // create+delete. This one assertion is the whole thesis.
    const pasted = subs.at(&doc, 6) orelse return error.NoIdOnPaste;
    try t.expectEqualStrings("7", pasted.fact("id").?);
    try t.expectEqualStrings("file", pasted.fact("kind").?);

    // Plain text (typed `o foo`, or a raw-text paste) restamps nothing: no
    // payloads means no id — a CREATE. Prove a register set from bytes with no
    // overlapping id-span ferries no identity.
    var plain: Register = .empty;
    defer plain.deinit(gpa);
    try plain.yank(gpa, &subs, &doc, .{ .start = 100, .end = 103 }, "foo", false);
    try t.expectEqual(@as(usize, 0), plain.payloads.items.len);
    try doc.insert(gpa, doc.text().byteLen(), "\nfoo");
    const typed_off = doc.text().byteLen() - 2;
    plain.restamp(gpa, &subs, &doc, doc.text().byteLen() - 3);
    try t.expect(subs.at(&doc, typed_off) == null); // no id on the typed line
}

test "register: one value per selection — distribute on a matching count, else paste the joined text" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    //             0123456789
    try doc.insert(gpa, 0, "foo bar\nbaz\n");
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);
    // An identity rides "bar" only.
    const row = try subs.claim(gpa, &doc, .{ .start = 4, .end = 7 });
    try row.putFact(gpa, "id", "b");

    var reg: Register = .empty;
    defer reg.deinit(gpa);
    try reg.yankEach(gpa, &subs, &doc, &.{
        .{ .range = .{ .start = 0, .end = 3 }, .bytes = "foo" },
        .{ .range = .{ .start = 4, .end = 7 }, .bytes = "bar" },
        .{ .range = .{ .start = 8, .end = 12 }, .bytes = "baz\n" },
    }, false);
    try t.expectEqual(@as(usize, 3), reg.valueCount());
    // Joined with a newline between values, none added after one that ends in one.
    try t.expectEqualStrings("foo\nbar\nbaz\n", reg.slice());

    // Three selections: each its own value.
    try t.expectEqualStrings("foo", reg.pasteValue(0, 3));
    try t.expectEqualStrings("bar", reg.pasteValue(1, 3));
    try t.expectEqualStrings("baz\n", reg.pasteValue(2, 3));
    // Any other count: everyone gets the whole joined text.
    try t.expectEqualStrings("foo\nbar\nbaz\n", reg.pasteValue(0, 1));
    try t.expectEqualStrings("foo\nbar\nbaz\n", reg.pasteValue(1, 2));

    // The identity follows ITS value: pasting value 1 alone re-stamps it at
    // that paste's base; pasting value 0 (no identity) creates none.
    const end = doc.text().byteLen();
    try doc.insert(gpa, end, "bar");
    reg.restampValue(gpa, &subs, &doc, end, 1, 3);
    try t.expectEqualStrings("b", (subs.at(&doc, end + 1) orelse return error.NoIdOnPaste).fact("id").?);
    const end2 = doc.text().byteLen();
    try doc.insert(gpa, end2, "foo");
    reg.restampValue(gpa, &subs, &doc, end2, 0, 3);
    try t.expect(subs.at(&doc, end2 + 1) == null);

    // A single-value yank is one value spanning the whole text — the
    // single-cursor register, unchanged.
    try reg.yank(gpa, null, &doc, .{ .start = 0, .end = 3 }, "foo", true);
    try t.expectEqual(@as(usize, 1), reg.valueCount());
    try t.expectEqualStrings("foo", reg.pasteValue(0, 1));
    try t.expectEqualStrings("foo", reg.pasteValue(2, 3));
}

test "register bank keeps named text after later unnamed delete yank" {
    var bank: Bank = .{};
    defer bank.deinit(std.testing.allocator);
    var doc = try Document.init(std.testing.allocator, "alpha\nbeta");
    defer doc.deinit(std.testing.allocator);
    try bank.yank(std.testing.allocator, 1, null, &doc, .{ .start = 0, .end = 5 }, "alpha", true);
    // A later ordinary delete/yank updates unnamed only; `a` remains stable.
    try bank.yank(std.testing.allocator, 0, null, &doc, .{ .start = 6, .end = 10 }, "beta", true);
    try std.testing.expectEqualStrings("alpha", bank.get(1).?.slice());
    try std.testing.expectEqualStrings("beta", bank.get(0).?.slice());
}

test {
    std.testing.refAllDecls(@This());
}
