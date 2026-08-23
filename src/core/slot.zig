//! core/slot.zig — `SlotHost`: the generic, schema-directed sibling of
//! `capability.zig`'s query/session machinery (D2, doc/d2-schema-payloads.md
//! §3.2/§6). Where `capability.Caps` races closed-`Payload`-union results
//! through `Kind`-typed sessions, `SlotHost` races raw schema-encoded byte
//! payloads through Container slots declared+bound at RUNTIME
//! (`wl_slot_declare`/`wl_slot_bind`) — no core type for the payload shape,
//! ever, the whole point of the fork (§6's worked "ui/badge" example).
//!
//! Deliberately NOT folded into `capability.zig`: this slice's job is
//! proving the generic membrane verbs + the schema marshaller end to end
//! WITHOUT touching the completion path (`Caps`/`Payload`/`wl_caps_*`) — that
//! migration is later, named and gated in doc/d2-schema-payloads.md §5.3 (the
//! "primary — the caps.push schema cutover" gate). `SlotHost` is `Caps`'s
//! sibling, structured identically on purpose (register/fire/push/decline/
//! finish, `Provider`/`Result`/`Session` all shaped the same way) so a later
//! fold-in, if/when the primary demolition gate fires, is a mechanical merge
//! of two same-shaped modules, not a redesign.

const std = @import("std");
const Allocator = std.mem.Allocator;
const container_mod = @import("container.zig");
const facts_mod = @import("facts.zig");
const schema_mod = @import("schema.zig");

pub const Schema = schema_mod.Schema;
pub const Facts = facts_mod.Facts;

/// What a schema-provider's handler receives — the sibling of
/// `capability.Request`. `payload` is the REQUEST side's schema-encoded
/// bytes (§3.2's `wl_payload_read` source) — borrowed for the duration of a
/// synchronous call; an async provider copies what it needs before deferring.
pub const Request = struct {
    session: u64,
    slot: []const u8,
    schema: *const Schema,
    payload: []const u8,
};

pub const Provider = struct {
    slot: []u8,
    owner: []u8,
    data: ?*anyopaque = null,
    handler: *const fn (data: ?*anyopaque, host: *SlotHost, req: *const Request) anyerror!void,
    /// Per-registration unique key — same reasoning as
    /// `container.ProviderRef.caps_provider`'s `seq`: `owner` alone cannot
    /// safely find a struct back (nothing in this domain re-registers the
    /// same owner per-scope today, but the lookup discipline is copied
    /// verbatim rather than re-litigated).
    seq: u64 = 0,

    fn deinit(self: *Provider, gpa: Allocator) void {
        gpa.free(self.slot);
        gpa.free(self.owner);
    }
};

pub const Result = struct {
    provider: []u8,
    /// Schema-encoded payload bytes, RESTAMPED against the session's fired
    /// version via `schema.walk`'s `.on_range` arm (§4) before storage — owned.
    payload: []u8,

    fn deinit(self: *Result, gpa: Allocator) void {
        gpa.free(self.provider);
        gpa.free(self.payload);
    }
};

pub const Session = struct {
    slot: []u8,
    schema: *const Schema,
    version: []u8,
    /// Schema-encoded REQUEST payload (may be empty) — the generic successor
    /// to `capability.Request.text`'s prefix-carrying role; the host copies
    /// this into a guest's scratch buffer via `wl_payload_read`.
    request: []u8,
    outstanding: usize,
    results: std.ArrayList(Result) = .empty,
    fresh: usize = 0,

    fn deinit(self: *Session, gpa: Allocator) void {
        gpa.free(self.slot);
        gpa.free(self.version);
        gpa.free(self.request);
        for (self.results.items) |*r| r.deinit(gpa);
        self.results.deinit(gpa);
    }

    /// Results that arrived since the last poll.
    pub fn poll(self: *Session) []const Result {
        const new = self.results.items[self.fresh..];
        self.fresh = self.results.items.len;
        return new;
    }

    pub fn all(self: *const Session) []const Result {
        return self.results.items;
    }

    pub fn done(self: *const Session) bool {
        return self.outstanding == 0;
    }
};

pub const SlotHost = struct {
    gpa: Allocator,
    providers: std.ArrayList(Provider) = .empty,
    sessions: std.AutoHashMapUnmanaged(u64, *Session) = .empty,
    next_session: u64 = 1,
    next_provider_seq: u64 = 0,
    /// BORROWED (task #19's shared-Container fold-in convention, followed
    /// from day one here rather than retrofitted) — the same
    /// `container.Container` instance `capability.Caps`/`action.Actions`/the
    /// UI mesh bind into. Every schema-carrying slot name lives in the SAME
    /// flat Container namespace `edit/*`/`ui/*`/action names already share.
    container: *container_mod.Container,

    pub fn init(gpa: Allocator, container: *container_mod.Container) SlotHost {
        return .{ .gpa = gpa, .container = container };
    }

    pub fn deinit(self: *SlotHost) void {
        for (self.providers.items) |*p| p.deinit(self.gpa);
        self.providers.deinit(self.gpa);
        var it = self.sessions.valueIterator();
        while (it.next()) |s| {
            s.*.deinit(self.gpa);
            self.gpa.destroy(s.*);
        }
        self.sessions.deinit(self.gpa);
    }

    pub const RegisterSpec = struct {
        slot: []const u8,
        owner: []const u8,
        predicate: facts_mod.Predicate = .{ .all = &.{} },
        priority: i32 = 0,
        tier: container_mod.Tier = .plugin,
        data: ?*anyopaque = null,
        handler: *const fn (?*anyopaque, *SlotHost, *const Request) anyerror!void,
    };

    /// Bind a provider (`wl_slot_bind`) — the slot must already be declared
    /// (`Container.declareSlot`/`wl_slot_declare`); `Container.bind`'s own
    /// `error.UnknownSlot` enforces "a blob may bind only slots its manifest
    /// declares" (§2.2), unchanged, for this domain too.
    pub fn register(self: *SlotHost, spec: RegisterSpec) !void {
        const gpa = self.gpa;
        const slot_owned = try gpa.dupe(u8, spec.slot);
        errdefer gpa.free(slot_owned);
        const owner_owned = try gpa.dupe(u8, spec.owner);
        errdefer gpa.free(owner_owned);

        try self.providers.ensureUnusedCapacity(gpa, 1);
        const seq = self.next_provider_seq;
        self.next_provider_seq += 1;

        try self.container.bind(.{
            .slot = slot_owned,
            .provider = .{ .schema_provider = .{ .owner = owner_owned, .seq = seq } },
            .predicate = spec.predicate,
            .priority = spec.priority,
            .tier = spec.tier,
            .owner = owner_owned,
            .domain = .slot,
        });

        self.providers.appendAssumeCapacity(.{
            .slot = slot_owned,
            .owner = owner_owned,
            .data = spec.data,
            .handler = spec.handler,
            .seq = seq,
        });
    }

    /// Plugin teardown — same ordering discipline as
    /// `capability.Caps.unregisterByIdPrefix`: drop Container bindings FIRST
    /// (they borrow `slot`/`owner` from the `Provider` structs about to be
    /// freed).
    pub fn unregisterByOwnerPrefix(self: *SlotHost, owner_prefix: []const u8) void {
        self.container.unbindOwnerPrefix(.slot, owner_prefix);
        var i: usize = 0;
        while (i < self.providers.items.len) {
            if (std.mem.startsWith(u8, self.providers.items[i].owner, owner_prefix)) {
                var p = self.providers.swapRemove(i);
                p.deinit(self.gpa);
            } else i += 1;
        }
    }

    fn findProviderBySeq(self: *const SlotHost, seq: u64) ?*const Provider {
        for (self.providers.items) |*p| if (p.seq == seq) return p;
        return null;
    }

    pub const FireOptions = struct {
        request: []const u8 = &.{},
    };

    /// Fire `slot` at every eligible schema-provider — the Container's own
    /// slot declaration supplies the SCHEMA every participant marshals
    /// against (the "table-driven interpreter" §3.2 describes: the host
    /// holds only the tree, never a per-slot type). Returns a session id, or
    /// `null` when the slot is undeclared, has no schema, or nothing is
    /// eligible.
    pub fn fire(self: *SlotHost, slot: []const u8, facts: Facts, version: []const u8, opts: FireOptions) !?u64 {
        const gpa = self.gpa;
        const decl = self.container.slots.get(slot) orelse return null;
        const schema = decl.schema orelse return null;
        const elig = try self.container.eligible(gpa, slot, facts);
        defer gpa.free(elig);
        var matched: std.ArrayList(*const Provider) = .empty;
        defer matched.deinit(gpa);
        for (elig) |b| {
            const ref = switch (b.provider) {
                .schema_provider => |r| r,
                else => continue,
            };
            if (self.findProviderBySeq(ref.seq)) |p| try matched.append(gpa, p);
        }
        if (matched.items.len == 0) return null;

        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        s.* = .{
            .slot = try gpa.dupe(u8, slot),
            .schema = schema,
            .version = try gpa.dupe(u8, version),
            .request = try gpa.dupe(u8, opts.request),
            .outstanding = matched.items.len,
        };
        const id = self.next_session;
        self.next_session += 1;
        try self.sessions.put(gpa, id, s);

        const req: Request = .{ .session = id, .slot = slot, .schema = schema, .payload = opts.request };
        for (matched.items) |p| {
            p.handler(p.data, self, &req) catch |err| {
                std.log.warn("slot {s}: provider {s} failed: {t}", .{ slot, p.owner, err });
                if (self.sessions.get(id)) |live| live.outstanding -|= 1;
            };
        }
        return id;
    }

    pub fn session(self: *SlotHost, id: u64) ?*Session {
        return self.sessions.get(id);
    }

    pub fn finish(self: *SlotHost, id: u64) void {
        if (self.sessions.fetchRemove(id)) |kv| {
            kv.value.deinit(self.gpa);
            self.gpa.destroy(kv.value);
        }
    }

    pub const From = struct { owner: []const u8 };

    /// A provider pushes a schema-encoded payload for `id` (§3.2's
    /// `wl_payload_push`) — restamped ONCE via `schema.walk`'s `.on_range`
    /// arm against the session's fired version (§4: "the provider's claimed
    /// version is never trusted... the host restamps every `range` field's
    /// version to the fired version"). This is the restamp walk's first live
    /// caller — the mechanical proof `doc/d2-schema-payloads.md` §4 asks for
    /// ("`SlotHost.push` is this walk's first live caller").
    ///
    /// `.on_anchor` is intentionally left unwired HERE (schema.walk still
    /// visits anchor-marked fields and passes them through unchanged, per
    /// §4: "an anchor is NOT restamped — it is RESOLVED"): resolving an
    /// anchor needs a LIVE `Document` this generic, document-agnostic host
    /// has no handle to, and consolidating that resolution into
    /// `command.Context.checkDocRegion` (§4's last paragraph) is an EDIT
    /// chokepoint — a query-shaped UI/badge slot fired here is not an edit
    /// action. Named, not built, in this slice; see the D2 slice report.
    pub fn push(self: *SlotHost, id: u64, from: From, payload: []const u8) !void {
        const s = self.sessions.get(id) orelse return;
        const gpa = self.gpa;
        const Ctx = struct { version: []const u8 };
        var ctx: Ctx = .{ .version = s.version };
        const restamped = try schema_mod.walk(gpa, s.schema, payload, .{
            .ctx = &ctx,
            .on_range = struct {
                fn cb(c: ?*anyopaque, r: schema_mod.RangeWire) []const u8 {
                    _ = r; // the provider's claimed version is never trusted
                    const self2: *Ctx = @ptrCast(@alignCast(c.?));
                    return self2.version;
                }
            }.cb,
        });
        errdefer gpa.free(restamped);
        try s.results.append(gpa, .{ .provider = try gpa.dupe(u8, from.owner), .payload = restamped });
        s.outstanding -|= 1;
    }

    /// A provider that will never answer this session (dead, unsupported).
    pub fn decline(self: *SlotHost, id: u64) void {
        if (self.sessions.get(id)) |s| s.outstanding -|= 1;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const t = std.testing;

fn testSchema() Schema {
    return .{ .scalar = .u32 };
}

test "slot: declare/bind/fire/push round-trips a schema-encoded payload, restamping range fields" {
    const gpa = t.allocator;
    var container = container_mod.Container.init(gpa);
    defer container.deinit();

    const str_ty: Schema = .str;
    const range_ty: Schema = .range;
    const fields = [_]Schema.Field{
        .{ .name = "label", .ty = &str_ty },
        .{ .name = "loc", .ty = &range_ty },
    };
    const schema: Schema = .{ .@"struct" = &fields };

    try container.declareSlot(.{ .name = "ui/badge", .shape = .query, .composition = .ordered_union, .schema = &schema });

    var host = SlotHost.init(gpa, &container);
    defer host.deinit();

    const Impl = struct {
        fn handle(data: ?*anyopaque, h: *SlotHost, req: *const Request) anyerror!void {
            _ = data;
            const vals = [_]schema_mod.Value{
                .{ .str = "hi" },
                .{ .range = .{ .version = "stale", .start = 1, .end = 2 } },
            };
            const bytes = try schema_mod.encode(h.gpa, req.schema, .{ .@"struct" = &vals });
            defer h.gpa.free(bytes);
            try h.push(req.session, .{ .owner = "badge-plugin" }, bytes);
        }
    };
    try host.register(.{ .slot = "ui/badge", .owner = "badge-plugin", .handler = Impl.handle });

    const id = (try host.fire("ui/badge", .{}, "fired-v9", .{})).?;
    const s = host.session(id).?;
    try t.expectEqual(@as(usize, 1), s.all().len);
    const decoded = try schema_mod.decodeCursor(&schema, s.all()[0].payload).enterStruct();
    try t.expectEqualStrings("hi", try (try decoded.field("label")).?.asStr());
    const loc = try (try decoded.field("loc")).?.asRange();
    try t.expectEqualStrings("fired-v9", loc.version); // restamped, not "stale"
    try t.expectEqual(@as(u64, 1), loc.start);
    try t.expectEqual(@as(u64, 2), loc.end);

    host.finish(id);
    try t.expectEqual(@as(?*Session, null), host.session(id));
}

test "slot: fire returns null for an undeclared slot, a schema-less slot, or no eligible provider" {
    const gpa = t.allocator;
    var container = container_mod.Container.init(gpa);
    defer container.deinit();
    var host = SlotHost.init(gpa, &container);
    defer host.deinit();

    try t.expectEqual(@as(?u64, null), try host.fire("nope", .{}, "v1", .{}));

    try container.declareSlot(.{ .name = "ui/noschema", .shape = .query, .composition = .ordered_union });
    try t.expectEqual(@as(?u64, null), try host.fire("ui/noschema", .{}, "v1", .{}));

    const s: Schema = testSchema();
    try container.declareSlot(.{ .name = "ui/nobind", .shape = .query, .composition = .ordered_union, .schema = &s });
    try t.expectEqual(@as(?u64, null), try host.fire("ui/nobind", .{}, "v1", .{}));
}

test "slot: unregisterByOwnerPrefix drops the Container binding AND the provider" {
    const gpa = t.allocator;
    var container = container_mod.Container.init(gpa);
    defer container.deinit();
    var host = SlotHost.init(gpa, &container);
    defer host.deinit();

    const s: Schema = testSchema();
    try container.declareSlot(.{ .name = "ui/x", .shape = .query, .composition = .ordered_union, .schema = &s });
    const Impl = struct {
        fn handle(data: ?*anyopaque, h: *SlotHost, req: *const Request) anyerror!void {
            _ = data;
            h.decline(req.session);
        }
    };
    try host.register(.{ .slot = "ui/x", .owner = "plugin.x", .handler = Impl.handle });
    try t.expectEqual(@as(usize, 1), host.providers.items.len);

    host.unregisterByOwnerPrefix("plugin.x");
    try t.expectEqual(@as(usize, 0), host.providers.items.len);
    try t.expectEqual(@as(?u64, null), try host.fire("ui/x", .{}, "v1", .{}));
}

test {
    std.testing.refAllDecls(@This());
}
