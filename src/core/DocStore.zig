//! DocStore — where a scratch document goes when nothing holds it open any
//! more and it has fallen out of `Buffers.parked` (doc/model.md §2.1: a
//! document "survives restart"). Documents are kept SERIALIZED, keyed by
//! their minted id, so a closed scratch outlives both the parked bound and
//! the process: `open weft://here/doc/<id>` — typed, a jumplist entry, an
//! embed — restores it on demand through `Buffers.revive`, the one route a
//! parked document already comes back by.
//!
//! **A record** is what makes the document the document: its id, its display
//! name, and its CRDT history (`Document.serialize`, the whole-history
//! bootstrap batch), restored the way `Document.addPeer` builds a replica
//! (`Document.restore`). A document whose history exceeds `history_cap` is
//! kept as its TEXT instead (`Document.restoreContent`, the bulk-load path):
//! the history is lost, the id and every byte are not — a document is never
//! dropped for being too big. What is NOT in a record is local session state:
//! the commit log, and so the undo stack that subscribes to it, anchors,
//! peers, the caret. A restored document's undo reaches back to the restore.
//!
//! **Bounded** by count: at most `doc_cap` records, the oldest evicted first
//! ("oldest" by when it was last put, so re-keeping a document refreshes
//! it). Per record, the history form is bounded by `history_cap`; the
//! content form is the user's text and is not, for the reason above.
//!
//! **Shape.** The records live in a `kv.Store` (namespace `doc`, key the
//! spelled id, value the encoded record), not in a structure of their own,
//! so the disk half is `kv_file`'s — one blob format, one load/save path,
//! one failure policy — and this module stays pure: it does no I/O. A value
//! is `stamp (u64 LE) · form (u8) · name length (u16 LE) · name · payload`,
//! the stamp being what orders records for eviction. A record that does not
//! decode is dropped when the store is loaded (`settle`); one whose history
//! does not restore is refused when read and KEPT (`restore` says why) —
//! never a crash, and never a user's text discarded on a guess.

const std = @import("std");
const Allocator = std.mem.Allocator;

const kv = @import("kv.zig");
const Document = @import("Document.zig");

const DocStore = @This();

/// Every record, in `kv` shape (see the module doc). Exposed for exactly one
/// reader: the disk binding, which loads and saves it wholesale.
records: kv.Store = .empty,
/// The stamp the next `put` takes. Above every stamp held, so the record
/// put last is always the newest (`settle` re-derives it after a load).
next_stamp: u64 = 1,

/// How many documents are kept. Past it, the one put longest ago goes.
pub const doc_cap = 32;
/// The largest HISTORY a record keeps (1 MiB). A document whose serialized
/// history is larger is kept as its text (see the module doc).
pub const history_cap = 1 << 20;
/// A name longer than this is kept cut (at a character boundary): a record
/// carries a display name, not an unbounded field.
pub const name_cap = 1024;

/// The `kv` namespace every record lives under.
pub const namespace = "doc";

pub const Form = enum(u8) {
    /// The payload is `Document.serialize`'s whole history.
    history = 1,
    /// The payload is the document's text alone.
    content = 2,
};

const header_len = 8 + 1 + 2;

pub fn deinit(self: *DocStore, gpa: Allocator) void {
    self.records.deinit(gpa);
    self.* = undefined;
}

fn bucket(self: *const DocStore) ?*const std.StringHashMapUnmanaged([]u8) {
    return self.records.ns.getPtr(namespace);
}

pub fn count(self: *const DocStore) usize {
    const b = self.bucket() orelse return 0;
    return b.count();
}

pub fn contains(self: *const DocStore, id: Document.Id) bool {
    const key = id.text();
    return self.records.get(namespace, &key) != null;
}

/// Keep `doc` (displayed as `name`) as the newest record, replacing any
/// record of the same id, then evict past `doc_cap`. Serializes now: the
/// caller may destroy `doc` as soon as this returns.
///
/// A document that is not `storable` — one ever bound to a peer — is not
/// kept, and any record of its id is dropped: this store is written to the
/// local disk, and another's text never reaches it through here, whoever
/// asks. Answers whether it was kept.
pub fn put(self: *DocStore, gpa: Allocator, name: []const u8, doc: *const Document) Allocator.Error!bool {
    if (!doc.storable()) {
        self.forget(gpa, doc.id);
        return false;
    }
    const history = try doc.serialize(gpa);
    defer gpa.free(history);
    const content = if (history.len > history_cap) try textOf(gpa, doc) else null;
    defer if (content) |c| gpa.free(c);
    const form: Form = if (content != null) .content else .history;
    const payload = content orelse history;
    const kept_name = cutName(name);

    const value = try gpa.alloc(u8, header_len + kept_name.len + payload.len);
    defer gpa.free(value);
    std.mem.writeInt(u64, value[0..8], self.next_stamp, .little);
    value[8] = @intFromEnum(form);
    std.mem.writeInt(u16, value[9..11], @intCast(kept_name.len), .little);
    @memcpy(value[header_len..][0..kept_name.len], kept_name);
    @memcpy(value[header_len + kept_name.len ..], payload);

    const key = doc.id.text();
    try self.records.put(gpa, namespace, &key, value);
    self.next_stamp += 1;
    self.trim(gpa);
    return true;
}

fn textOf(gpa: Allocator, doc: *const Document) Allocator.Error![]u8 {
    const rope = doc.text();
    const out = try gpa.alloc(u8, rope.byteLen());
    errdefer gpa.free(out);
    var sr = rope.streamReader(.{ .start = 0, .end = out.len }, &.{});
    sr.interface.readSliceAll(out) catch unreachable; // whole range, in bounds
    return out;
}

/// `name`, cut to `name_cap` without splitting a character.
fn cutName(name: []const u8) []const u8 {
    if (name.len <= name_cap) return name;
    var end: usize = name_cap;
    while (end > 0 and name[end] & 0xc0 == 0x80) end -= 1;
    return name[0..end];
}

/// A record taken back out: the document, and the name it was shown under
/// (owned; free both).
pub const Restored = struct {
    doc: Document,
    name: []u8,
};

/// Restore document `id` as the user peer `user_agent`'s replica. The record
/// STAYS: reading a document back is not yet holding it, and a reopen that
/// fails after this (the entry cannot be made) must leave the document where
/// it was. The caller `forget`s the record once something holds the
/// document — so it lives in exactly one place at a time, and in at least
/// one at every moment. Null when no record is `id`'s, or when its history
/// does not restore (warned, and the record kept: whether a restore failed
/// for the record's sake or for the allocator's is not something a failure
/// deep in the history decoder reliably says, and discarding a user's text on
/// a guess is the one outcome this store exists to prevent; the count bound
/// evicts it in time).
pub fn restore(self: *const DocStore, gpa: Allocator, user_agent: []const u8, id: Document.Id) Allocator.Error!?Restored {
    const key = id.text();
    const value = self.records.get(namespace, &key) orelse return null;
    return restoreRecord(gpa, user_agent, id, value) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Corrupt => {
            std.log.warn("documents: the record for {s} does not restore — kept, not opened", .{&key});
            return null;
        },
    };
}

/// Drop `id`'s record: its document is held open now (`restore`'s caller,
/// once the entry stands). Frees; cannot fail.
pub fn forget(self: *DocStore, gpa: Allocator, id: Document.Id) void {
    const key = id.text();
    _ = self.records.del(gpa, namespace, &key);
}

fn restoreRecord(gpa: Allocator, user_agent: []const u8, id: Document.Id, value: []const u8) Document.RestoreError!Restored {
    const record = decode(value) orelse return error.Corrupt;
    const name = try gpa.dupe(u8, record.name);
    errdefer gpa.free(name);
    const doc = switch (record.form) {
        .history => try Document.restore(gpa, user_agent, id, record.payload),
        .content => try Document.restoreContent(gpa, user_agent, id, record.payload),
    };
    return .{ .doc = doc, .name = name };
}

const Decoded = struct { stamp: u64, form: Form, name: []const u8, payload: []const u8 };

fn decode(value: []const u8) ?Decoded {
    if (value.len < header_len) return null;
    const form = std.enums.fromInt(Form, value[8]) orelse return null;
    const name_len = std.mem.readInt(u16, value[9..11], .little);
    if (value.len - header_len < name_len) return null;
    const name = value[header_len..][0..name_len];
    if (!std.unicode.utf8ValidateSlice(name)) return null;
    return .{
        .stamp = std.mem.readInt(u64, value[0..8], .little),
        .form = form,
        .name = name,
        .payload = value[header_len + name_len ..],
    };
}

/// Make the records honest after they were loaded wholesale (`kv_file` loads
/// the store, not this module): drop every record whose key is not a spelled
/// id or whose value does not decode, evict past `doc_cap` — a file written
/// under a larger bound, or edited by hand — and put `next_stamp` above every
/// stamp held, so a put after the load is the newest. Namespaces other than
/// `doc` are never read, so they are left alone.
pub fn settle(self: *DocStore, gpa: Allocator) void {
    while (self.dropFirstMalformed(gpa)) {}
    self.trim(gpa);
    var newest: u64 = 0;
    if (self.bucket()) |b| {
        var it = b.iterator();
        while (it.next()) |e| newest = @max(newest, decode(e.value_ptr.*).?.stamp);
    }
    self.next_stamp = newest + 1;
}

/// Remove one malformed record, if there is one. Removes through the bucket
/// itself (freeing what `kv.Store` owns, as its `del` would) because a
/// malformed key can be any length, so there is no fixed buffer to copy it
/// into first.
fn dropFirstMalformed(self: *DocStore, gpa: Allocator) bool {
    const b = self.records.ns.getPtr(namespace) orelse return false;
    var it = b.iterator();
    while (it.next()) |e| {
        if (Document.Id.parse(e.key_ptr.*) != null and decode(e.value_ptr.*) != null) continue;
        std.log.warn("documents: a stored record does not decode — discarded", .{});
        const key = e.key_ptr.*;
        const value = e.value_ptr.*;
        b.removeByPtr(e.key_ptr);
        gpa.free(key);
        gpa.free(value);
        return true;
    }
    return false;
}

/// Evict the oldest records until at most `doc_cap` remain. Every key here
/// is a spelled id and every value decodes (`put` writes only those;
/// `settle` drops the rest).
fn trim(self: *DocStore, gpa: Allocator) void {
    while (self.count() > doc_cap) {
        const b = self.bucket().?;
        var oldest: ?struct { stamp: u64, key: [Document.Id.text_len]u8 } = null;
        var it = b.iterator();
        while (it.next()) |e| {
            const stamp = decode(e.value_ptr.*).?.stamp;
            if (oldest) |o| if (o.stamp <= stamp) continue;
            oldest = .{ .stamp = stamp, .key = e.key_ptr.*[0..Document.Id.text_len].* };
        }
        _ = self.records.del(gpa, namespace, &oldest.?.key);
    }
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;
const Editor = @import("Editor.zig");
const task = @import("task.zig");
const undo = @import("undo.zig");

fn textAlloc(doc: *const Document) ![]u8 {
    return textOf(t.allocator, doc);
}

test "doc store: a kept document comes back with its id, its text and its name, and takes further edits, undo and keeping again" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var store: DocStore = .{};
    defer store.deinit(gpa);

    var original = try Editor.init(gpa, pool, "user");
    try original.insertText(gpa, "hello");
    original.moveTo(5);
    try original.insertText(gpa, " world\n");
    const id = original.doc.id;
    _ = try store.put(gpa, "*notes*", &original.doc);
    original.deinit(gpa); // the store holds bytes, not the document
    try t.expect(store.contains(id));

    var restored = (try store.restore(gpa, "user", id)).?;
    defer gpa.free(restored.name);
    // Restoring is not holding: the record stays until it is forgotten.
    try t.expect(store.contains(id));
    store.forget(gpa, id);
    try t.expect(!store.contains(id));
    try t.expectEqualStrings("*notes*", restored.name);
    try t.expect(restored.doc.id.eql(id));
    var ed = try Editor.around(gpa, pool, &restored.doc);
    defer ed.deinit(gpa);
    {
        const text = try textAlloc(&ed.doc);
        defer gpa.free(text);
        try t.expectEqualStrings("hello world\n", text);
    }

    // It is a working document: an edit lands, and undo takes back exactly
    // that edit — the history before the restore is text, not undo units.
    ed.moveTo(0);
    try ed.insertText(gpa, "> ");
    try t.expect(try ed.undo(gpa, undo.Gate.user_driven));
    try t.expect(!try ed.undo(gpa, undo.Gate.user_driven));
    ed.moveTo(12);
    try ed.insertText(gpa, "again\n");

    // …and it can be kept again, and come back again, edits and all.
    _ = try store.put(gpa, "*notes*", &ed.doc);
    var twice = (try store.restore(gpa, "user", id)).?;
    defer twice.doc.deinit(gpa);
    defer gpa.free(twice.name);
    const text = try textAlloc(&twice.doc);
    defer gpa.free(text);
    try t.expectEqualStrings("hello world\nagain\n", text);
}

test "doc store: past the bound the record put longest ago goes, and putting again refreshes" {
    const gpa = t.allocator;
    var store: DocStore = .{};
    defer store.deinit(gpa);
    var ids: [doc_cap + 1]Document.Id = undefined;
    for (&ids, 0..) |*id, i| {
        var doc = try Document.init(gpa, "user");
        defer doc.deinit(gpa);
        try doc.insert(gpa, 0, "x");
        id.* = doc.id;
        _ = try store.put(gpa, "d", &doc);
        // Re-keep the first just before the bound bites: it is now newer
        // than the second, so the second is the one evicted.
        if (i == doc_cap - 1) {
            var again = (try store.restore(gpa, "user", ids[0])).?;
            defer again.doc.deinit(gpa);
            defer gpa.free(again.name);
            _ = try store.put(gpa, "d", &again.doc);
        }
    }
    try t.expectEqual(@as(usize, doc_cap), store.count());
    try t.expect(store.contains(ids[0]));
    try t.expect(!store.contains(ids[1]));
    try t.expect(store.contains(ids[doc_cap]));
}

test "doc store: a history past the cap is kept as its text — the id and every byte survive" {
    const gpa = t.allocator;
    var store: DocStore = .{};
    defer store.deinit(gpa);
    const big = try gpa.alloc(u8, history_cap + 1024);
    defer gpa.free(big);
    for (big, 0..) |*c, i| c.* = if (i % 64 == 63) '\n' else 'a' + @as(u8, @intCast(i % 26));

    var doc = try Document.init(gpa, "user");
    try doc.insert(gpa, 0, big);
    const id = doc.id;
    _ = try store.put(gpa, "big", &doc);
    doc.deinit(gpa);

    const key = id.text();
    try t.expectEqual(Form.content, decode(store.records.get(namespace, &key).?).?.form);
    var back = (try store.restore(gpa, "user", id)).?;
    defer back.doc.deinit(gpa);
    defer gpa.free(back.name);
    try t.expect(back.doc.id.eql(id));
    const text = try textAlloc(&back.doc);
    defer gpa.free(text);
    try t.expectEqualSlices(u8, big, text);
    // Still a document you can type into.
    try back.doc.insert(gpa, 0, "top\n");
    try t.expectEqual(big.len + 4, back.doc.text().byteLen());
}

test "doc store: a record whose history does not restore is refused and kept; garbage is dropped at load" {
    const gpa = t.allocator;
    var store: DocStore = .{};
    defer store.deinit(gpa);
    const id = Document.mintId();
    const key = id.text();

    // A header that decodes, over a history that does not.
    var value: [header_len + 5]u8 = undefined;
    std.mem.writeInt(u64, value[0..8], 1, .little);
    value[8] = @intFromEnum(Form.history);
    std.mem.writeInt(u16, value[9..11], 0, .little);
    @memcpy(value[header_len..], "junk!");
    try store.records.put(gpa, namespace, &key, &value);
    try t.expect((try store.restore(gpa, "user", id)) == null);
    // Kept: a failed restore never costs the record (see `restore`).
    try t.expect(store.contains(id));
    store.forget(gpa, id);

    // Loaded garbage — a key that is no id, a value with no header — is
    // dropped by `settle`, and what is sound stays.
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "sound");
    _ = try store.put(gpa, "ok", &doc);
    try store.records.put(gpa, namespace, "not-an-id", &value);
    const other = Document.mintId().text();
    try store.records.put(gpa, namespace, &other, "short");
    store.settle(gpa);
    try t.expectEqual(@as(usize, 1), store.count());
    try t.expect(store.contains(doc.id));
    try t.expect(store.next_stamp > 1);
}
