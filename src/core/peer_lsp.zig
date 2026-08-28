//! peer_lsp — the TYPED language-service export
//! (doc/contextual-workspace-architecture.md §14.4: "Remote LSP exports typed
//! language protocols, never JSON-RPC"), the endpoint sibling of `peer_fs`.
//!
//! A peer holding this publication's `lsp` export asks a typed question —
//! completion, hover, definition — about a document in the GRANTED DOCUMENT
//! SET, and gets typed positions and items back. No JSON-RPC crosses the
//! wire in either direction: the owner answers out of its OWN language
//! sessions (the multi-session table behind `Service`) and re-states the
//! answer in this file's vocabulary, which is `capability.zig`'s shapes
//! (`CompletionItem`, `Location`) narrowed to what a wire can carry.
//!
//! Three gates, in the order a request meets them:
//!
//! 1. **the grant** — `Grant` defaults to deny, and is checked before the
//!    request is even parsed, exactly like `peer_fs`: an ungranted export is
//!    refused on its own terms, not by what it asked. `error.NotGranted`,
//!    which the caller answers with `lsp_err`/`.not_granted`, so the
//!    requester settles NOW instead of waiting out its deadline.
//! 2. **the document set** — a question about a document this publication
//!    does not export is `out_of_scope`, never answered from a document the
//!    peer cannot see.
//! 3. **the answer's own references** — a result pointing at a document
//!    outside the set is WITHHELD owner-side (see `putLocations`).
//!
//! **Honest v1 scope.** The granted set is the WHOLE published set, not one
//! document per grant; and only a location's document is filtered, not the
//! prose inside a hover. Both narrowings are named where they would live.
//!
//! **Honest v1 timing.** `Service.answer` is synchronous: the owner answers
//! from what its language sessions can produce during the call, and answers
//! `unavailable` otherwise. Parking a peer's request until an async
//! `capability.Caps` session settles — so a `slow` provider can still be the
//! one that answers — is the deferred half; the requester's own deadline
//! (`session/requests.zig`) already bounds the wait either way.
//!
//! **Honest provenance.** The `Service` seam is implemented by the owner's
//! composition, not by core, and no production composition installs one yet
//! — the export is protocol, gate, and gates-in-tests, the same "landed,
//! tested, not yet consumed" standing `grants.zig` names for its own
//! unwired consumers. Its first implementation is a `capability.Caps`
//! adapter (fire `edit/completion` and friends at the owner's own
//! providers), which is exactly what the timing deferral above is about.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The typed questions this export answers. `_` so a newer peer's question
/// decodes as unknown and is refused, never mistaken for a neighbour.
pub const Op = enum(u8) { completion = 0, hover = 1, definition = 2, _ };

/// How an answered call came out. A refusal for want of a grant is NOT here
/// — it rides `lsp_err`/`.not_granted`, so "you may not ask" never looks
/// like "here is an empty answer".
pub const Status = enum(u8) { ok = 0, unavailable = 1, out_of_scope = 2, bad = 3 };

/// Which language-service surfaces a peer holds. One in v1 (`query`);
/// mutating surfaces — workspace edits, rename — are a separate export
/// §14.4 already says needs its own explicit grant. Defaults to deny.
pub const Grant = struct {
    query: bool = false,

    pub const none: Grant = .{};
    pub const all: Grant = .{ .query = true };
};

/// The request asks for a surface this peer was not granted.
pub const Refusal = error{NotGranted};

/// The documents this export answers for: v1 is the publication's whole
/// published set (§14.4's "document-scoped code intelligence filters results
/// and opening to the granted document" — the per-grant narrowing to ONE
/// document is the deferred half, see the module doc). Names are BORROWED
/// for the duration of a call, and are the publication's own resource names
/// — the durable `weft://` target grammar (doc/substrate.md §7) is what a
/// later version designates with.
pub const DocumentSet = struct {
    names: []const []const u8 = &.{},

    pub fn contains(self: DocumentSet, name: []const u8) bool {
        for (self.names) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }
};

/// One typed question. `offset` is a byte offset in `document` at the
/// requester's revision; `text` is the completion prefix (empty otherwise).
pub const Request = struct {
    op: Op,
    document: []const u8,
    offset: u64,
    text: []const u8,
};

/// `capability.CompletionItem`, narrowed to what the wire carries.
pub const Item = struct {
    text: []const u8,
    label: []const u8 = &.{},
    detail: []const u8 = &.{},
    kind: u8 = 0,
    rank: i32 = 0,
};

/// `capability.Location`, with the document named rather than a stamped
/// range: a stamp is meaningless on a replica that never saw that version.
pub const Location = struct {
    document: []const u8,
    start: u64,
    end: u64,
};

/// What the owner's language sessions produced. Borrowed for the duration
/// of the `answer` call — the owner keeps it alive, this file only encodes.
pub const Answer = union(enum) {
    items: []const Item,
    text: []const u8,
    locations: []const Location,
};

/// The owner's language service, owned OUTSIDE core (same seam as
/// `peer_fs.Service`): core knows the question and the answer's shape, never
/// a server, a protocol, or a session table. `null` = this owner has no
/// answer to give right now, which the peer reads as `unavailable`.
pub const Service = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        answer: *const fn (*anyopaque, Allocator, Request) Allocator.Error!?Answer,
    };

    pub fn init(pointer: anytype) Service {
        const Pointer = @TypeOf(pointer);
        const info = switch (@typeInfo(Pointer)) {
            .pointer => |value| value,
            else => @compileError("peer language service requires a pointer"),
        };
        if (info.size != .one or info.is_const)
            @compileError("peer language service requires a mutable single-item pointer");
        const Implementation = info.child;
        const Adapter = struct {
            fn answer(raw: *anyopaque, gpa: Allocator, req: Request) Allocator.Error!?Answer {
                const self: *Implementation = @ptrCast(@alignCast(raw));
                return self.answer(gpa, req);
            }
            const vtable: VTable = .{ .answer = @This().answer };
        };
        return .{ .context = pointer, .vtable = &Adapter.vtable };
    }

    pub fn answer(self: Service, gpa: Allocator, req: Request) Allocator.Error!?Answer {
        return self.vtable.answer(self.context, gpa, req);
    }
};

// ── Wire codec ──────────────────────────────────────────────────────
// Request: u8 op | uv doc_len | doc | uv offset | uv text_len | text.
// Reply:   u8 status | body, empty for every status but `ok`.
//   completion: uv n | n × ( item text | label | detail | u8 kind | uv rank )
//   hover:      uv len | text
//   definition: uv n | n × ( uv doc_len | doc | uv start | uv end )

const wire = @import("weft_wire");

fn putBytes(gpa: Allocator, out: *std.ArrayList(u8), b: []const u8) Allocator.Error!void {
    try wire.putUv(gpa, out, b.len);
    try out.appendSlice(gpa, b);
}

fn getBytes(cur: *[]const u8) ?[]const u8 {
    const n = wire.getUv(cur) catch return null;
    if (n > cur.len) return null;
    const out = cur.*[0..@intCast(n)];
    cur.* = cur.*[@intCast(n)..];
    return out;
}

/// Encode one question (caller owns the bytes).
pub fn encodeRequest(gpa: Allocator, req: Request) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, @intFromEnum(req.op));
    try putBytes(gpa, &out, req.document);
    try wire.putUv(gpa, &out, req.offset);
    try putBytes(gpa, &out, req.text);
    return out.toOwnedSlice(gpa);
}

/// Parse one question; borrowed from `req`. Null on anything malformed.
pub fn decodeRequest(req: []const u8) ?Request {
    if (req.len == 0) return null;
    var cur = req[1..];
    const document = getBytes(&cur) orelse return null;
    const offset = wire.getUv(&cur) catch return null;
    const text = getBytes(&cur) orelse return null;
    return .{ .op = @enumFromInt(req[0]), .document = document, .offset = offset, .text = text };
}

/// A decoded reply: the status, and the body to read the typed answer out
/// of (borrowed from the reply bytes).
pub const Reply = struct { status: Status, body: []const u8 };

pub fn decodeReply(resp: []const u8) ?Reply {
    if (resp.len == 0) return null;
    return .{ .status = std.enums.fromInt(Status, resp[0]) orelse return null, .body = resp[1..] };
}

/// Read completion items out of an `ok` reply's body, in order. Each item
/// borrows from `body`; iteration ends at the first malformed record rather
/// than inventing one.
pub const ItemIterator = struct {
    cur: []const u8,
    left: u64,

    pub fn next(self: *ItemIterator) ?Item {
        if (self.left == 0) return null;
        self.left -= 1;
        const text = getBytes(&self.cur) orelse return null;
        const label = getBytes(&self.cur) orelse return null;
        const detail = getBytes(&self.cur) orelse return null;
        if (self.cur.len == 0) return null;
        const kind = self.cur[0];
        self.cur = self.cur[1..];
        const rank = wire.getUv(&self.cur) catch return null;
        return .{
            .text = text,
            .label = label,
            .detail = detail,
            .kind = kind,
            .rank = @bitCast(@as(u32, @truncate(rank))),
        };
    }
};

pub fn items(body: []const u8) ItemIterator {
    var cur = body;
    const n = wire.getUv(&cur) catch 0;
    return .{ .cur = cur, .left = n };
}

/// The same, for definition/reference locations.
pub const LocationIterator = struct {
    cur: []const u8,
    left: u64,

    pub fn next(self: *LocationIterator) ?Location {
        if (self.left == 0) return null;
        self.left -= 1;
        const document = getBytes(&self.cur) orelse return null;
        const start = wire.getUv(&self.cur) catch return null;
        const end = wire.getUv(&self.cur) catch return null;
        return .{ .document = document, .start = start, .end = end };
    }
};

pub fn locations(body: []const u8) LocationIterator {
    var cur = body;
    const n = wire.getUv(&cur) catch 0;
    return .{ .cur = cur, .left = n };
}

// ── Server ──────────────────────────────────────────────────────────

fn refuse(gpa: Allocator, status: Status) Allocator.Error![]u8 {
    return gpa.dupe(u8, &[_]u8{@intFromEnum(status)});
}

/// Answer one typed language-service call. `docs` is the granted document
/// set, `service` the owner's own language sessions. Returns the owned
/// reply bytes; `error.NotGranted` when this peer holds no `lsp` export.
pub fn handle(
    gpa: Allocator,
    grant: Grant,
    docs: DocumentSet,
    service: ?Service,
    req: []const u8,
) (Allocator.Error || Refusal)![]u8 {
    // Gate 1, before the request is parsed: an ungranted export is refused
    // on its own terms, not by what it asked.
    if (!grant.query) return error.NotGranted;
    const parsed = decodeRequest(req) orelse return refuse(gpa, .bad);
    switch (parsed.op) {
        .completion, .hover, .definition => {},
        _ => return refuse(gpa, .bad),
    }
    // Gate 2: a question about a document this publication does not export.
    if (!docs.contains(parsed.document)) return refuse(gpa, .out_of_scope);
    const svc = service orelse return refuse(gpa, .unavailable);
    const got = try svc.answer(gpa, parsed) orelse return refuse(gpa, .unavailable);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, @intFromEnum(Status.ok));
    switch (got) {
        .items => |list| {
            try wire.putUv(gpa, &out, list.len);
            for (list) |it| {
                try putBytes(gpa, &out, it.text);
                try putBytes(gpa, &out, it.label);
                try putBytes(gpa, &out, it.detail);
                try out.append(gpa, it.kind);
                try wire.putUv(gpa, &out, @as(u32, @bitCast(it.rank)));
            }
        },
        // Gate 3 for prose is the DEFERRED half: a hover body can quote a
        // definition site the peer may not see, and this v1 forwards it
        // whole. The filter belongs here, beside the location one below,
        // once a hover carries the designations it quotes.
        .text => |body| try putBytes(gpa, &out, body),
        .locations => |list| try putLocations(gpa, &out, docs, list),
    }
    return out.toOwnedSlice(gpa);
}

/// Gate 3: a result pointing OUTSIDE the granted set never leaves the
/// owner. Withheld one by one — the peer gets the answers it may see rather
/// than a whole refusal for one stray reference — and each withholding is
/// one line in the owner's log, so it is a decision, not a silence.
fn putLocations(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    docs: DocumentSet,
    list: []const Location,
) Allocator.Error!void {
    var kept: usize = 0;
    for (list) |l| {
        if (docs.contains(l.document)) kept += 1;
    }
    try wire.putUv(gpa, out, kept);
    for (list) |l| {
        if (!docs.contains(l.document)) {
            std.log.warn("peer_lsp: withheld a result in {s} — outside the granted document set", .{l.document});
            continue;
        }
        try putBytes(gpa, out, l.document);
        try wire.putUv(gpa, out, l.start);
        try wire.putUv(gpa, out, l.end);
    }
}

// ── tests ───────────────────────────────────────────────────────────

const t = std.testing;

/// A hermetic language service: answers from a fixed table, never a server.
const FakeService = struct {
    asked: usize = 0,
    reply: Answer,

    pub fn answer(self: *FakeService, _: Allocator, _: Request) Allocator.Error!?Answer {
        self.asked += 1;
        return self.reply;
    }
};

test "peer_lsp: a granted completion round-trips as typed items, never JSON" {
    const gpa = t.allocator;
    var svc: FakeService = .{ .reply = .{ .items = &.{
        .{ .text = "parseHeader", .label = "parseHeader(bytes)", .detail = "fn", .kind = 3, .rank = -2 },
        .{ .text = "parseBody", .kind = 3, .rank = 5 },
    } } };
    const docs: DocumentSet = .{ .names = &.{"parser.zig"} };

    const req = try encodeRequest(gpa, .{ .op = .completion, .document = "parser.zig", .offset = 42, .text = "pars" });
    defer gpa.free(req);
    const resp = try handle(gpa, .all, docs, Service.init(&svc), req);
    defer gpa.free(resp);

    const reply = decodeReply(resp).?;
    try t.expectEqual(Status.ok, reply.status);
    var it = items(reply.body);
    const first = it.next().?;
    try t.expectEqualStrings("parseHeader", first.text);
    try t.expectEqualStrings("parseHeader(bytes)", first.label);
    try t.expectEqualStrings("fn", first.detail);
    try t.expectEqual(@as(u8, 3), first.kind);
    try t.expectEqual(@as(i32, -2), first.rank); // negative ranks survive
    const second = it.next().?;
    try t.expectEqualStrings("parseBody", second.text);
    try t.expectEqual(@as(i32, 5), second.rank);
    try t.expectEqual(@as(?Item, null), it.next());
    try t.expectEqual(@as(usize, 1), svc.asked);
}

test "peer_lsp: no grant refuses BEFORE the question is parsed; an unknown question is bad" {
    const gpa = t.allocator;
    var svc: FakeService = .{ .reply = .{ .text = "docs" } };
    const docs: DocumentSet = .{ .names = &.{"parser.zig"} };

    try t.expectError(error.NotGranted, handle(gpa, .none, docs, Service.init(&svc), "not even a request"));
    try t.expectEqual(@as(usize, 0), svc.asked); // the service was never reached

    // A question a newer peer invented decodes as unknown and is refused,
    // never routed to a neighbouring op.
    const alien = try encodeRequest(gpa, .{ .op = @enumFromInt(200), .document = "parser.zig", .offset = 0, .text = "" });
    defer gpa.free(alien);
    const bad = try handle(gpa, .all, docs, Service.init(&svc), alien);
    defer gpa.free(bad);
    try t.expectEqual(Status.bad, decodeReply(bad).?.status);
    try t.expectEqual(@as(usize, 0), svc.asked);
}

test "peer_lsp: a document outside the granted set is never asked about, and an owner with no service says so" {
    const gpa = t.allocator;
    var svc: FakeService = .{ .reply = .{ .text = "secret" } };
    const docs: DocumentSet = .{ .names = &.{"parser.zig"} };

    const req = try encodeRequest(gpa, .{ .op = .hover, .document = "secrets.zig", .offset = 0, .text = "" });
    defer gpa.free(req);
    const resp = try handle(gpa, .all, docs, Service.init(&svc), req);
    defer gpa.free(resp);
    try t.expectEqual(Status.out_of_scope, decodeReply(resp).?.status);
    try t.expectEqual(@as(usize, 0), svc.asked);

    const mine = try encodeRequest(gpa, .{ .op = .hover, .document = "parser.zig", .offset = 0, .text = "" });
    defer gpa.free(mine);
    const none_resp = try handle(gpa, .all, docs, null, mine);
    defer gpa.free(none_resp);
    try t.expectEqual(Status.unavailable, decodeReply(none_resp).?.status);
}

test "peer_lsp: a definition outside the granted set is withheld; the in-set ones still answer" {
    const gpa = t.allocator;
    var svc: FakeService = .{ .reply = .{ .locations = &.{
        .{ .document = "parser.zig", .start = 10, .end = 21 },
        .{ .document = "private.zig", .start = 0, .end = 4 },
        .{ .document = "parser.zig", .start = 90, .end = 96 },
    } } };
    const docs: DocumentSet = .{ .names = &.{"parser.zig"} };

    const req = try encodeRequest(gpa, .{ .op = .definition, .document = "parser.zig", .offset = 12, .text = "" });
    defer gpa.free(req);
    const resp = try handle(gpa, .all, docs, Service.init(&svc), req);
    defer gpa.free(resp);

    const reply = decodeReply(resp).?;
    try t.expectEqual(Status.ok, reply.status);
    var it = locations(reply.body);
    const a = it.next().?;
    try t.expectEqualStrings("parser.zig", a.document);
    try t.expectEqual(@as(u64, 10), a.start);
    const b = it.next().?;
    try t.expectEqual(@as(u64, 90), b.start);
    try t.expectEqual(@as(?Location, null), it.next()); // private.zig never left
    // The withheld one is not even named in the reply bytes.
    try t.expect(std.mem.indexOf(u8, resp, "private.zig") == null);
}

test {
    std.testing.refAllDecls(@This());
}
