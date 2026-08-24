//! core/schema.zig — D2's schema language + marshaller
//! (doc/d2-schema-payloads.md §2/§3). Pure Zig over slices and a small
//! owned-tree representation: no wasmtime, no wasm_host/*, no gfx, no
//! stemma — the SAME dependency posture as core/membrane/contract_data.zig
//! (§3.2's explicit call-out), so this file compiles under
//! wasm32-freestanding and a guest SDK can import it identically to the
//! host (§3.3's runtime-fallback interpreter path). Read
//! doc/d2-schema-payloads.md in full before touching this file.
//!
//! **Non-overlap with contract_data.zig, stated at the function level
//! (§3.2), because "rhymes with" is not a design**: this file never
//! declares a `wl_*` call and never knows a slot NAME — `contract_data.zig`
//! stays the sole authority on the membrane's fixed CALL surface (which
//! `wl_*` imports exist, their arity, their perm gate). This file only knows
//! how to turn a `Schema` tree + a `Value` tree into bytes and back
//! (`encode`/`decodeCursor`), how to walk those bytes by SHAPE alone
//! (`walk`, the restamp/anchor visitor, §4), and how a `Schema` VALUE itself
//! serializes (`canonicalizeSchema`/`parseSchema`, the "meta-schema", §2.2
//! form 2). The four new `wl_slot_*`/`wl_payload_*` imports
//! (core/membrane/contract_data.zig) carry `(SchemaRef version, ptr, len)`
//! scalars; this file interprets what's behind `(ptr, len)` once the host
//! has copied it out of guest memory. One seam, both ways — schema.zig never
//! declares a call, contract_data.zig never inspects a payload's structure.
//!
//! **Wire conventions reused verbatim from wire.zig** (§1's "the wire
//! conventions D2 aligns to"): length/count prefixes are LEB128 varints
//! (`wire.putUv`/`wire.getUv`, imported directly — wire.zig has the same
//! zero-host-dependency posture, so importing it does not smuggle in a
//! wasmtime/gfx edge); scalars are fixed-width little-endian
//! (`std.mem.writeInt`/`readInt`), never varint-framed — "lean in to c": a
//! schema-directed payload is laid out like a packed C struct, not a
//! self-describing tag soup (§1).
//!
//! **Hostile input, stated as policy**: every decode path here is
//! bounds-checked at every step. A truncated or malicious payload returns
//! `error.Corrupt` (or `error.SchemaMismatch` for a shape mismatch) — it
//! NEVER over-reads, never panics on a safety-checked slice op, and never
//! trusts a length prefix without checking it against the bytes actually
//! remaining. This is what makes §2.3's evolution rules work without special
//! casing: a struct decoded against an OLDER schema than its producer's
//! simply never reads the producer's trailing extra field bytes (trailing
//! tolerance falls out of "only ever consume what your own schema's fields
//! require"); a struct decoded against a NEWER schema than its producer's
//! runs out of bytes trying to read a field the producer never wrote, and
//! that short read is exactly `error.Corrupt` — the loud refusal §2.3
//! demands, not a silent third result.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("weft_wire");

// ── The schema language (§2.1) ──────────────────────────────────────────

/// Fixed-width, little-endian, C-packed. No varint for scalars — a schema
/// field's width is known from its type, so this is both compact and
/// zero-ambiguity (uv stays reserved for lengths/counts, where the value IS
/// a size and varint pays off).
pub const Scalar = enum(u8) { bool, i32, i64, u32, u64, f32, f64 };

fn scalarWidth(s: Scalar) usize {
    return switch (s) {
        .bool => 1,
        .i32, .u32, .f32 => 4,
        .i64, .u64, .f64 => 8,
    };
}

/// A `Schema` is a tree. `variant` is a bounded, tagged union: its case
/// metadata is carried by the schema, while the wire carries only the case
/// index and that case's payload. The case name is metadata, just like a
/// struct field name, and never crosses the payload wire.
pub const Schema = union(enum) {
    scalar: Scalar,
    /// utf8, uv-length-framed, validated at the boundary (`Cursor.asStr`).
    str,
    /// opaque, uv-length-framed — kept distinct from `str` on purpose (a
    /// wasm blob / image is not utf8).
    bytes,
    /// uv count, then N elements of the element schema.
    array: *const Schema,
    /// fields in declared order, no padding, no field tags on the wire — the
    /// field NAME is metadata (codegen/explain/evolution), never crosses.
    @"struct": []const Field,
    /// one presence byte (0/1), then the element if present.
    optional: *const Schema,
    /// schema-MARKED: a stemma EventAnchor (identity) — §4's `.on_anchor`.
    anchor,
    /// schema-MARKED: a StampedRange (version + [s,e)) — §4's `.on_range`.
    range,
    /// bounded tag (a case index), followed by the selected case payload.
    variant: []const Case,

    pub const Field = struct { name: []const u8, ty: *const Schema };
    pub const Case = struct { name: []const u8, ty: *const Schema };
    /// Descriptive alias for callers that want to make the tagged-union
    /// intent explicit at call sites (`Schema.VariantCase`).
    pub const VariantCase = Case;
};

/// The wire form of an `anchor`-marked field — `(agent, seq, side)`, the
/// portable identity `EventAnchor`/`Document.EventAnchor`/`grants.EventAnchor`
/// already use, restated structurally here (no stemma import: this file
/// doesn't know the concrete `EventAnchor` TYPE, only its wire shape — a
/// host-side adapter converts between this and `Document.EventAnchor`).
/// `side` is the raw `AnchorSide` byte (0/1 by that enum's own tag order);
/// this file never interprets it, only carries it through.
pub const AnchorWire = struct { agent: []const u8, seq: u64, side: u8 };

/// The wire form of a `range`-marked field — `(version, start, end)`, the
/// `StampedRange` shape restated structurally (same reasoning as
/// `AnchorWire`: no `position.zig` import needed, only the wire shape).
pub const RangeWire = struct { version: []const u8, start: u64, end: u64 };

/// A tagged leaf/branch value fed to `encode` — the source `encode` walks in
/// lockstep with a `Schema` tree. Positional for `struct` (matching the
/// schema's field order; field NAMES are schema metadata, never carried
/// here either) — this is the marshaller's own in-memory value
/// representation, distinct from `Schema` (the TYPE) the same way a JSON
/// value is distinct from a JSON schema.
pub const Value = union(enum) {
    scalar: ScalarValue,
    str: []const u8,
    bytes: []const u8,
    array: []const Value,
    @"struct": []const Value,
    optional: ?*const Value,
    anchor: AnchorWire,
    range: RangeWire,
    variant: VariantValue,
};

/// The selected payload for a `Schema.variant`. `tag` is an index into the
/// schema's case table, not an open-ended wire enum. A pointer keeps the
/// representation consistent with `Value.optional` while allowing every
/// payload shape, including an empty struct, to be selected.
pub const VariantValue = struct { tag: usize, payload: *const Value };
pub const Variant = VariantValue;

pub const ScalarValue = union(Scalar) {
    bool: bool,
    i32: i32,
    i64: i64,
    u32: u32,
    u64: u64,
    f32: f32,
    f64: f64,
};

// ── Encode (§3.1: a pre-order walk, no tags, no padding) ────────────────

pub const EncodeError = error{ SchemaMismatch, InvalidSchema } || Allocator.Error;

/// Encode `value` against `schema` — a pre-order walk emitting bytes with NO
/// tags and NO padding (§3.1). `error.SchemaMismatch` when `value`'s shape
/// doesn't match `schema` at some node (a caller bug, not a wire-corruption
/// case — decode's `error.Corrupt` is the untrusted-input sibling of this).
pub fn encode(gpa: Allocator, schema: *const Schema, value: Value) EncodeError![]u8 {
    try validateSchema(schema);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try encodeInto(gpa, &list, schema, value);
    return list.toOwnedSlice(gpa);
}

/// Encode with the producer's `SchemaRef` version prefixed as a uv (§2.3:
/// "a payload is prefixed with its producer's SchemaRef version") — the
/// small, well-justified extension to §3.2's four listed functions that the
/// wire convention itself requires somewhere; kept here rather than
/// duplicated at every call site (`wl_payload_push`'s host handler, the
/// e2e's guest fixture, and the meta-schema blob's own future use all need
/// it identically).
pub fn encodeVersioned(gpa: Allocator, version: u32, schema: *const Schema, value: Value) EncodeError![]u8 {
    try validateSchema(schema);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try wire.putUv(gpa, &list, version);
    try encodeInto(gpa, &list, schema, value);
    return list.toOwnedSlice(gpa);
}

pub const VersionedPayload = struct { version: u32, rest: []const u8 };

/// Split a versioned payload's leading uv version tag from its schema-encoded
/// body — the mirror of `encodeVersioned`. `rest` borrows `bytes`.
pub fn splitVersion(bytes: []const u8) DecodeError!VersionedPayload {
    var cur = bytes;
    const v = wire.getUv(&cur) catch return error.Corrupt;
    if (v > std.math.maxInt(u32)) return error.Corrupt;
    return .{ .version = @intCast(v), .rest = cur };
}

fn writeScalar(gpa: Allocator, list: *std.ArrayList(u8), v: ScalarValue) Allocator.Error!void {
    switch (v) {
        .bool => |b| try list.append(gpa, @intFromBool(b)),
        inline .i32, .u32 => |x| {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(@TypeOf(x), &buf, x, .little);
            try list.appendSlice(gpa, &buf);
        },
        inline .i64, .u64 => |x| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(@TypeOf(x), &buf, x, .little);
            try list.appendSlice(gpa, &buf);
        },
        .f32 => |x| {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, @bitCast(x), .little);
            try list.appendSlice(gpa, &buf);
        },
        .f64 => |x| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @bitCast(x), .little);
            try list.appendSlice(gpa, &buf);
        },
    }
}

fn encodeInto(gpa: Allocator, list: *std.ArrayList(u8), schema: *const Schema, value: Value) EncodeError!void {
    switch (schema.*) {
        .scalar => |sk| {
            if (value != .scalar or @as(Scalar, value.scalar) != sk) return error.SchemaMismatch;
            try writeScalar(gpa, list, value.scalar);
        },
        .str => {
            if (value != .str) return error.SchemaMismatch;
            try wire.putUv(gpa, list, value.str.len);
            try list.appendSlice(gpa, value.str);
        },
        .bytes => {
            if (value != .bytes) return error.SchemaMismatch;
            try wire.putUv(gpa, list, value.bytes.len);
            try list.appendSlice(gpa, value.bytes);
        },
        .array => |elem| {
            if (value != .array) return error.SchemaMismatch;
            try wire.putUv(gpa, list, value.array.len);
            for (value.array) |v| try encodeInto(gpa, list, elem, v);
        },
        .@"struct" => |fields| {
            if (value != .@"struct" or value.@"struct".len != fields.len) return error.SchemaMismatch;
            for (fields, value.@"struct") |f, v| try encodeInto(gpa, list, f.ty, v);
        },
        .optional => |elem| {
            if (value != .optional) return error.SchemaMismatch;
            if (value.optional) |inner| {
                try list.append(gpa, 1);
                try encodeInto(gpa, list, elem, inner.*);
            } else {
                try list.append(gpa, 0);
            }
        },
        .anchor => {
            if (value != .anchor) return error.SchemaMismatch;
            const a = value.anchor;
            try wire.putUv(gpa, list, a.agent.len);
            try list.appendSlice(gpa, a.agent);
            try wire.putUv(gpa, list, a.seq);
            try list.append(gpa, a.side);
        },
        .range => {
            if (value != .range) return error.SchemaMismatch;
            const r = value.range;
            try wire.putUv(gpa, list, r.version.len);
            try list.appendSlice(gpa, r.version);
            try wire.putUv(gpa, list, r.start);
            try wire.putUv(gpa, list, r.end);
        },
        .variant => |cases| {
            if (value != .variant or value.variant.tag >= cases.len) return error.SchemaMismatch;
            try wire.putUv(gpa, list, value.variant.tag);
            try encodeInto(gpa, list, cases[value.variant.tag].ty, value.variant.payload.*);
        },
    }
}

// ── Decode: the dynamic cursor (§3.1/§3.3 — the runtime interpreter path) ─

pub const DecodeError = error{ Corrupt, SchemaMismatch };

/// A value's position in a schema-encoded buffer: WHAT it should be
/// (`schema`) and WHERE its bytes start (`bytes`, which may extend past the
/// end of this one value — every reader here consumes only what its own
/// schema node needs and never assumes `bytes` ends exactly at the value's
/// boundary, which is what makes trailing-field tolerance free, §2.3).
pub const Cursor = struct {
    schema: *const Schema,
    bytes: []const u8,

    /// The byte length `self`'s value occupies, WITHOUT materializing it —
    /// the primitive `field`/array-indexing skip past a value they don't
    /// want reuses. Every branch bounds-checks before slicing; a truncated
    /// buffer returns `error.Corrupt`, never a safety-checked-slice panic.
    fn skip(self: Cursor) DecodeError!usize {
        switch (self.schema.*) {
            .scalar => |sk| {
                const w = scalarWidth(sk);
                if (self.bytes.len < w) return error.Corrupt;
                return w;
            },
            .str, .bytes => {
                var cur = self.bytes;
                const n = wire.getUv(&cur) catch return error.Corrupt;
                const hdr = self.bytes.len - cur.len;
                if (n > cur.len) return error.Corrupt;
                return hdr + @as(usize, @intCast(n));
            },
            .array => |elem| {
                var cur = self.bytes;
                const count = wire.getUv(&cur) catch return error.Corrupt;
                var consumed = self.bytes.len - cur.len;
                var i: u64 = 0;
                while (i < count) : (i += 1) {
                    if (consumed > self.bytes.len) return error.Corrupt;
                    const sub: Cursor = .{ .schema = elem, .bytes = self.bytes[consumed..] };
                    consumed += try sub.skip();
                }
                return consumed;
            },
            .@"struct" => |fields| {
                var consumed: usize = 0;
                for (fields) |f| {
                    if (consumed > self.bytes.len) return error.Corrupt;
                    const sub: Cursor = .{ .schema = f.ty, .bytes = self.bytes[consumed..] };
                    consumed += try sub.skip();
                }
                return consumed;
            },
            .optional => |elem| {
                if (self.bytes.len < 1) return error.Corrupt;
                if (self.bytes[0] == 0) return 1;
                const sub: Cursor = .{ .schema = elem, .bytes = self.bytes[1..] };
                return 1 + try sub.skip();
            },
            .anchor => {
                var cur = self.bytes;
                const alen = wire.getUv(&cur) catch return error.Corrupt;
                var consumed = self.bytes.len - cur.len;
                if (alen > cur.len) return error.Corrupt;
                consumed += @as(usize, @intCast(alen));
                if (consumed > self.bytes.len) return error.Corrupt;
                cur = self.bytes[consumed..];
                _ = wire.getUv(&cur) catch return error.Corrupt; // seq
                consumed = self.bytes.len - cur.len;
                if (consumed >= self.bytes.len) return error.Corrupt; // 1 side byte still needed
                return consumed + 1;
            },
            .range => {
                var cur = self.bytes;
                const vlen = wire.getUv(&cur) catch return error.Corrupt;
                var consumed = self.bytes.len - cur.len;
                if (vlen > cur.len) return error.Corrupt;
                consumed += @as(usize, @intCast(vlen));
                if (consumed > self.bytes.len) return error.Corrupt;
                cur = self.bytes[consumed..];
                _ = wire.getUv(&cur) catch return error.Corrupt; // start
                _ = wire.getUv(&cur) catch return error.Corrupt; // end
                return self.bytes.len - cur.len;
            },
            .variant => |cases| {
                var cur = self.bytes;
                const tag = wire.getUv(&cur) catch return error.Corrupt;
                if (tag >= cases.len) return error.Corrupt;
                const sub: Cursor = .{ .schema = cases[@intCast(tag)].ty, .bytes = cur };
                return (self.bytes.len - cur.len) + try sub.skip();
            },
        }
    }

    fn requireScalar(self: Cursor, comptime want: Scalar) DecodeError![scalarWidth(want)]u8 {
        if (self.schema.* != .scalar or self.schema.scalar != want) return error.SchemaMismatch;
        const w = comptime scalarWidth(want);
        if (self.bytes.len < w) return error.Corrupt;
        var out: [w]u8 = undefined;
        @memcpy(&out, self.bytes[0..w]);
        return out;
    }

    pub fn asBool(self: Cursor) DecodeError!bool {
        const b = try self.requireScalar(.bool);
        return b[0] != 0;
    }
    pub fn asI32(self: Cursor) DecodeError!i32 {
        return std.mem.readInt(i32, &(try self.requireScalar(.i32)), .little);
    }
    pub fn asU32(self: Cursor) DecodeError!u32 {
        return std.mem.readInt(u32, &(try self.requireScalar(.u32)), .little);
    }
    pub fn asI64(self: Cursor) DecodeError!i64 {
        return std.mem.readInt(i64, &(try self.requireScalar(.i64)), .little);
    }
    pub fn asU64(self: Cursor) DecodeError!u64 {
        return std.mem.readInt(u64, &(try self.requireScalar(.u64)), .little);
    }
    pub fn asF32(self: Cursor) DecodeError!f32 {
        return @bitCast(std.mem.readInt(u32, &(try self.requireScalar(.f32)), .little));
    }
    pub fn asF64(self: Cursor) DecodeError!f64 {
        return @bitCast(std.mem.readInt(u64, &(try self.requireScalar(.f64)), .little));
    }

    pub fn asStr(self: Cursor) DecodeError![]const u8 {
        if (self.schema.* != .str) return error.SchemaMismatch;
        var cur = self.bytes;
        const n = wire.getUv(&cur) catch return error.Corrupt;
        if (n > cur.len) return error.Corrupt;
        const s = cur[0..@intCast(n)];
        if (!std.unicode.utf8ValidateSlice(s)) return error.Corrupt;
        return s;
    }
    pub fn asBytes(self: Cursor) DecodeError![]const u8 {
        if (self.schema.* != .bytes) return error.SchemaMismatch;
        var cur = self.bytes;
        const n = wire.getUv(&cur) catch return error.Corrupt;
        if (n > cur.len) return error.Corrupt;
        return cur[0..@intCast(n)];
    }
    pub fn asAnchor(self: Cursor) DecodeError!AnchorWire {
        if (self.schema.* != .anchor) return error.SchemaMismatch;
        var cur = self.bytes;
        const alen = wire.getUv(&cur) catch return error.Corrupt;
        if (alen > cur.len) return error.Corrupt;
        const agent = cur[0..@intCast(alen)];
        cur = cur[@intCast(alen)..];
        const seq = wire.getUv(&cur) catch return error.Corrupt;
        if (cur.len < 1) return error.Corrupt;
        return .{ .agent = agent, .seq = seq, .side = cur[0] };
    }
    pub fn asRange(self: Cursor) DecodeError!RangeWire {
        if (self.schema.* != .range) return error.SchemaMismatch;
        var cur = self.bytes;
        const vlen = wire.getUv(&cur) catch return error.Corrupt;
        if (vlen > cur.len) return error.Corrupt;
        const version = cur[0..@intCast(vlen)];
        cur = cur[@intCast(vlen)..];
        const start = wire.getUv(&cur) catch return error.Corrupt;
        const end = wire.getUv(&cur) catch return error.Corrupt;
        return .{ .version = version, .start = start, .end = end };
    }

    /// Enter a tagged variant and validate its bounded case index. The
    /// selected payload is borrowed from `self.bytes`; reading it is still
    /// bounds-checked by the returned cursor.
    pub fn enterVariant(self: Cursor) DecodeError!VariantCursor {
        const cases = if (self.schema.* == .variant) self.schema.variant else return error.SchemaMismatch;
        var cur = self.bytes;
        const raw_tag = wire.getUv(&cur) catch return error.Corrupt;
        if (raw_tag >= cases.len) return error.Corrupt;
        const tag: usize = @intCast(raw_tag);
        return .{ .cases = cases, .tag = tag, .payload = .{ .schema = cases[tag].ty, .bytes = cur } };
    }

    /// `null` when absent; else a sub-cursor over the element.
    pub fn enterOptional(self: Cursor) DecodeError!?Cursor {
        const elem = if (self.schema.* == .optional) self.schema.optional else return error.SchemaMismatch;
        if (self.bytes.len < 1) return error.Corrupt;
        if (self.bytes[0] == 0) return null;
        return .{ .schema = elem, .bytes = self.bytes[1..] };
    }

    pub fn enterArray(self: Cursor) DecodeError!ArrayCursor {
        const elem = if (self.schema.* == .array) self.schema.array else return error.SchemaMismatch;
        var cur = self.bytes;
        const count = wire.getUv(&cur) catch return error.Corrupt;
        return .{ .elem = elem, .bytes = cur, .count = count };
    }

    pub fn enterStruct(self: Cursor) DecodeError!StructCursor {
        const fields = if (self.schema.* == .@"struct") self.schema.@"struct" else return error.SchemaMismatch;
        return .{ .fields = fields, .all_bytes = self.bytes };
    }
};

pub const ArrayCursor = struct {
    elem: *const Schema,
    bytes: []const u8,
    count: u64,
    idx: u64 = 0,

    pub fn len(self: ArrayCursor) usize {
        return @intCast(self.count);
    }

    /// `nextScalar`/`enterArray`/`enterStruct`'s array sibling — sequential
    /// walk, `null` when exhausted.
    pub fn next(self: *ArrayCursor) DecodeError!?Cursor {
        if (self.idx >= self.count) return null;
        const cur: Cursor = .{ .schema = self.elem, .bytes = self.bytes };
        const n = try cur.skip();
        if (n > self.bytes.len) return error.Corrupt;
        self.bytes = self.bytes[n..];
        self.idx += 1;
        return cur;
    }
};

/// A dynamically decoded variant. `tag` is guaranteed to be in `cases`; use
/// `selected()` for a cursor over its payload and `caseName()` for metadata.
pub const VariantCursor = struct {
    cases: []const Schema.Case,
    tag: usize,
    payload: Cursor,

    pub fn selected(self: VariantCursor) Cursor {
        return self.payload;
    }

    pub fn caseName(self: VariantCursor) []const u8 {
        return self.cases[self.tag].name;
    }

    pub fn caseMetadata(self: VariantCursor) Schema.Case {
        return self.cases[self.tag];
    }
};

pub const StructCursor = struct {
    fields: []const Schema.Field,
    /// Bytes at the START of field 0 — kept fixed so `field(name)` can
    /// always re-derive a byte offset from scratch (structs have no random-
    /// access index on the wire; a named lookup is an O(fields) walk that
    /// SKIPS, never materializes, everything before the match).
    all_bytes: []const u8,

    /// `cur.field("count").asU32()` — the §3.3 runtime-interpreter ergonomic
    /// this file exists to make possible for a guest that never saw this
    /// slot's schema at build time. `null` if `name` isn't a field.
    pub fn field(self: StructCursor, name: []const u8) DecodeError!?Cursor {
        var rest = self.all_bytes;
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return .{ .schema = f.ty, .bytes = rest };
            const sub: Cursor = .{ .schema = f.ty, .bytes = rest };
            const n = try sub.skip();
            if (n > rest.len) return error.Corrupt;
            rest = rest[n..];
        }
        return null;
    }

    /// Sequential, in-declaration-order walk — the `nextScalar`/`enterArray`/
    /// `enterStruct` cursor primitives §3.1 names, struct-shaped: each call
    /// returns the next field's name + cursor, or `null` when exhausted.
    pub fn iter(self: StructCursor) StructIter {
        return .{ .fields = self.fields, .bytes = self.all_bytes };
    }
};

pub const StructIter = struct {
    fields: []const Schema.Field,
    bytes: []const u8,
    idx: usize = 0,

    pub fn next(self: *StructIter) DecodeError!?struct { name: []const u8, cur: Cursor } {
        if (self.idx >= self.fields.len) return null;
        const f = self.fields[self.idx];
        const cur: Cursor = .{ .schema = f.ty, .bytes = self.bytes };
        const n = try cur.skip();
        if (n > self.bytes.len) return error.Corrupt;
        self.bytes = self.bytes[n..];
        self.idx += 1;
        return .{ .name = f.name, .cur = cur };
    }
};

/// The dynamic walk's entry point (§3.2's listed surface): a `Cursor`
/// positioned at the top of `bytes`, described by `schema`. Never fails —
/// every fallible step is deferred to the first read/enter call, so a
/// caller that never reads never pays for validation it doesn't need.
pub fn decodeCursor(schema: *const Schema, bytes: []const u8) Cursor {
    return .{ .schema = schema, .bytes = bytes };
}

// ── walk: the restamp/grant visitor (§4) ─────────────────────────────────

/// `.on_range` is called once per `range`-marked field, given its CURRENT
/// wire form, and returns the version bytes to stamp instead (§4: "the host
/// rewrites field.version := fired_version... the provider's claimed
/// version is never trusted"); returning the SAME bytes it was given is a
/// legal no-op rewrite. `.on_anchor` is called once per `anchor`-marked
/// field, read-only (§4: "an anchor is NOT restamped — it is RESOLVED
/// against the live document"); this file has no live document to resolve
/// against, so it only ever offers the raw wire form up to the caller.
/// Either callback may be `null` (a walk that only cares about one mark).
pub const RestampVisitor = struct {
    ctx: ?*anyopaque = null,
    on_range: ?*const fn (ctx: ?*anyopaque, r: RangeWire) []const u8 = null,
    on_anchor: ?*const fn (ctx: ?*anyopaque, a: AnchorWire) void = null,
};

/// Generalizes `capability.zig`'s three hand-walked `switch`es
/// (`restamp`/`dupePayload`/`Result.deinit`) into ONE schema-directed walk
/// (§4): copies `bytes` structurally (every scalar/str/bytes/array/struct/
/// optional field verbatim), calling `visitor.on_range`/`.on_anchor` for
/// each marked field it crosses. Returns a FRESH buffer rather than
/// mutating `bytes` in place — §4's pseudocode reads like an in-place
/// rewrite, but a `range`'s version token is a variable-length STRING
/// (`position.StampedRange._version: []const u8`, restated here as
/// `RangeWire.version`); a new stamp of a different byte length cannot
/// always be written into the old one's slot without shifting every byte
/// after it, so this walk allocates and copies once instead of mutating in
/// place. Still ONE traversal, one implementation, replacing three —
/// `SlotHost.push` (core/slot.zig) is this walk's first live caller (§4's
/// "on_range live on the new path").
pub fn walk(gpa: Allocator, schema: *const Schema, bytes: []const u8, visitor: RestampVisitor) (DecodeError || Allocator.Error)![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    _ = try walkInto(gpa, &out, schema, bytes, visitor);
    return out.toOwnedSlice(gpa);
}

fn walkInto(gpa: Allocator, out: *std.ArrayList(u8), schema: *const Schema, bytes: []const u8, visitor: RestampVisitor) (DecodeError || Allocator.Error)!usize {
    switch (schema.*) {
        .scalar => |sk| {
            const w = scalarWidth(sk);
            if (bytes.len < w) return error.Corrupt;
            try out.appendSlice(gpa, bytes[0..w]);
            return w;
        },
        .str, .bytes => {
            var cur = bytes;
            const n = wire.getUv(&cur) catch return error.Corrupt;
            const hdr = bytes.len - cur.len;
            if (n > cur.len) return error.Corrupt;
            try wire.putUv(gpa, out, n);
            try out.appendSlice(gpa, cur[0..@intCast(n)]);
            return hdr + @as(usize, @intCast(n));
        },
        .array => |elem| {
            var cur = bytes;
            const count = wire.getUv(&cur) catch return error.Corrupt;
            try wire.putUv(gpa, out, count);
            var consumed = bytes.len - cur.len;
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                if (consumed > bytes.len) return error.Corrupt;
                consumed += try walkInto(gpa, out, elem, bytes[consumed..], visitor);
            }
            return consumed;
        },
        .@"struct" => |fields| {
            var consumed: usize = 0;
            for (fields) |f| {
                if (consumed > bytes.len) return error.Corrupt;
                consumed += try walkInto(gpa, out, f.ty, bytes[consumed..], visitor);
            }
            return consumed;
        },
        .optional => |elem| {
            if (bytes.len < 1) return error.Corrupt;
            if (bytes[0] == 0) {
                try out.append(gpa, 0);
                return 1;
            }
            try out.append(gpa, 1);
            return 1 + try walkInto(gpa, out, elem, bytes[1..], visitor);
        },
        .anchor => {
            const cur: Cursor = .{ .schema = schema, .bytes = bytes };
            const a = try cur.asAnchor();
            if (visitor.on_anchor) |cb| cb(visitor.ctx, a);
            try wire.putUv(gpa, out, a.agent.len);
            try out.appendSlice(gpa, a.agent);
            try wire.putUv(gpa, out, a.seq);
            try out.append(gpa, a.side);
            return try cur.skip();
        },
        .range => {
            const cur: Cursor = .{ .schema = schema, .bytes = bytes };
            const r = try cur.asRange();
            const consumed = try cur.skip();
            const new_version = if (visitor.on_range) |cb| cb(visitor.ctx, r) else r.version;
            try wire.putUv(gpa, out, new_version.len);
            try out.appendSlice(gpa, new_version);
            try wire.putUv(gpa, out, r.start);
            try wire.putUv(gpa, out, r.end);
            return consumed;
        },
        .variant => |cases| {
            var cur = bytes;
            const raw_tag = wire.getUv(&cur) catch return error.Corrupt;
            if (raw_tag >= cases.len) return error.Corrupt;
            const tag: usize = @intCast(raw_tag);
            try wire.putUv(gpa, out, raw_tag);
            const n = try walkInto(gpa, out, cases[tag].ty, cur, visitor);
            return (bytes.len - cur.len) + n;
        },
    }
}

// ── The meta-schema: a Schema VALUE's own canonical blob (§2.2 form 2) ──
//
// A literal `Schema` value describing `Schema` generically cannot be built
// as a finite tree in THIS language: `Schema` is self-referential
// (`array`/`optional` hold `*const Schema`; `struct` holds `Field`s that
// hold `*const Schema`), and §2.1's constructor set deliberately excludes
// recursion/`ref` (a self-referential schema still cannot be expressed).
// Encoding a
// `Schema` tree is exactly that structural client, one layer too early for
// the language to serve generically — so `canonicalizeSchema`/`parseSchema`
// are a HAND-WRITTEN recursive codec (the same wire primitives — `putUv`,
// fixed-width LE — applied by hand, the way `contract_data.zig`'s own table
// is data ABOUT the contract without being parsed BY the contract's own
// mechanism). "Self-hosting" here means "the same wire primitives, applied
// to describe the language's own tree" — not "a `Schema` value that
// describes `Schema`," which the language cannot yet express. Named
// plainly, not smuggled: this is §7's frontier arriving one call early.

const tag_bool: u8 = 0;
const tag_i32: u8 = 1;
const tag_i64: u8 = 2;
const tag_u32: u8 = 3;
const tag_u64: u8 = 4;
const tag_f32: u8 = 5;
const tag_f64: u8 = 6;
const tag_str: u8 = 7;
const tag_bytes: u8 = 8;
const tag_array: u8 = 9;
const tag_struct: u8 = 10;
const tag_optional: u8 = 11;
const tag_anchor: u8 = 12;
const tag_range: u8 = 13;
const tag_variant: u8 = 14;

fn scalarTag(s: Scalar) u8 {
    return switch (s) {
        .bool => tag_bool,
        .i32 => tag_i32,
        .i64 => tag_i64,
        .u32 => tag_u32,
        .u64 => tag_u64,
        .f32 => tag_f32,
        .f64 => tag_f64,
    };
}

/// A `Schema` tree → its own canonical blob — the ONE deterministic
/// serialization §2.2 form 2 names (what a runtime-declared slot ships
/// through `wl_slot_declare`, what a remote head fetches for an unknown
/// slot). Byte-identical for byte-identical trees (no hash maps, no
/// nondeterministic iteration — a `struct`'s fields are already an ordered
/// slice).
pub const SchemaValidationError = error{InvalidSchema};

/// Validate schema metadata and recursive shape before it is used as a type.
/// This catches duplicate/empty case names, empty variants, unreasonable
/// metadata, and pointer cycles/depth bombs without importing a host runtime.
pub fn validateSchema(schema: *const Schema) SchemaValidationError!void {
    var state: ValidationState = .{};
    try validateSchemaInner(schema, &state, 0);
}

const maxSchemaDepth: usize = 256;
const maxSchemaNodes: usize = 1 << 20;
const maxSchemaName: usize = 1 << 20;

const ValidationState = struct { nodes: usize = 0 };

fn validateSchemaInner(schema: *const Schema, state: *ValidationState, depth: usize) SchemaValidationError!void {
    if (depth > maxSchemaDepth or state.nodes >= maxSchemaNodes) return error.InvalidSchema;
    state.nodes += 1;
    switch (schema.*) {
        .scalar, .str, .bytes, .anchor, .range => {},
        .array => |elem| try validateSchemaInner(elem, state, depth + 1),
        .optional => |elem| try validateSchemaInner(elem, state, depth + 1),
        .variant => |cases| {
            if (cases.len == 0 or cases.len > maxSchemaNodes) return error.InvalidSchema;
            for (cases, 0..) |c, i| {
                if (c.name.len == 0 or c.name.len > maxSchemaName) return error.InvalidSchema;
                for (cases[0..i]) |prior| {
                    if (std.mem.eql(u8, prior.name, c.name)) return error.InvalidSchema;
                }
                try validateSchemaInner(c.ty, state, depth + 1);
            }
        },
        .@"struct" => |fields| {
            if (fields.len > maxSchemaNodes) return error.InvalidSchema;
            for (fields, 0..) |f, i| {
                if (f.name.len == 0 or f.name.len > maxSchemaName) return error.InvalidSchema;
                for (fields[0..i]) |prior| {
                    if (std.mem.eql(u8, prior.name, f.name)) return error.InvalidSchema;
                }
                try validateSchemaInner(f.ty, state, depth + 1);
            }
        },
    }
}

pub fn canonicalizeSchema(gpa: Allocator, schema: *const Schema) (Allocator.Error || SchemaValidationError)![]u8 {
    try validateSchema(schema);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try canonicalizeInto(gpa, &list, schema);
    return list.toOwnedSlice(gpa);
}

fn canonicalizeInto(gpa: Allocator, list: *std.ArrayList(u8), schema: *const Schema) Allocator.Error!void {
    switch (schema.*) {
        .scalar => |sk| try list.append(gpa, scalarTag(sk)),
        .str => try list.append(gpa, tag_str),
        .bytes => try list.append(gpa, tag_bytes),
        .array => |elem| {
            try list.append(gpa, tag_array);
            try canonicalizeInto(gpa, list, elem);
        },
        .@"struct" => |fields| {
            try list.append(gpa, tag_struct);
            try wire.putUv(gpa, list, fields.len);
            for (fields) |f| {
                try wire.putUv(gpa, list, f.name.len);
                try list.appendSlice(gpa, f.name);
                try canonicalizeInto(gpa, list, f.ty);
            }
        },
        .optional => |elem| {
            try list.append(gpa, tag_optional);
            try canonicalizeInto(gpa, list, elem);
        },
        .anchor => try list.append(gpa, tag_anchor),
        .range => try list.append(gpa, tag_range),
        .variant => |cases| {
            try list.append(gpa, tag_variant);
            try wire.putUv(gpa, list, cases.len);
            for (cases) |c| {
                try wire.putUv(gpa, list, c.name.len);
                try list.appendSlice(gpa, c.name);
                try canonicalizeInto(gpa, list, c.ty);
            }
        },
    }
}

/// `canonicalizeSchema`'s inverse — a HEAP-OWNED tree (every `*const Schema`
/// node individually `gpa.create`d, every field name `gpa.dupe`d): the host
/// side of `wl_slot_declare` ("host decodes the schema blob via
/// `schema.canonicalizeSchema`'s inverse and calls `Container.declareSlot`",
/// §3.2). Free the result with `freeSchema` — NEVER call `freeSchema` on a
/// `Schema` value this module didn't allocate (a `const`/comptime-authored
/// tree, e.g. a plugin's own static schema literal): ownership is exactly
/// "did `parseSchema` build it," the same convention `container.zig`'s
/// `SlotDecl.schema` borrow already assumes.
pub fn parseSchema(gpa: Allocator, bytes: []const u8) (DecodeError || Allocator.Error)!*const Schema {
    var cur = bytes;
    var state: ParseState = .{ .gpa = gpa };
    const s = parseOne(&state, &cur, 0) catch |err| return err;
    if (cur.len != 0) {
        freeSchema(gpa, s);
        return error.Corrupt;
    }
    return s;
}

const ParseState = struct { gpa: Allocator, nodes: usize = 0 };

fn parseOne(state: *ParseState, cur: *[]const u8, depth: usize) (DecodeError || Allocator.Error)!*Schema {
    const gpa = state.gpa;
    if (depth > maxSchemaDepth or state.nodes >= maxSchemaNodes) return error.Corrupt;
    state.nodes += 1;
    if (cur.len < 1) return error.Corrupt;
    const tag = cur.*[0];
    cur.* = cur.*[1..];
    const node = try gpa.create(Schema);
    errdefer gpa.destroy(node);
    node.* = switch (tag) {
        tag_bool => .{ .scalar = .bool },
        tag_i32 => .{ .scalar = .i32 },
        tag_i64 => .{ .scalar = .i64 },
        tag_u32 => .{ .scalar = .u32 },
        tag_u64 => .{ .scalar = .u64 },
        tag_f32 => .{ .scalar = .f32 },
        tag_f64 => .{ .scalar = .f64 },
        tag_str => .str,
        tag_bytes => .bytes,
        tag_anchor => .anchor,
        tag_range => .range,
        tag_array => .{ .array = try parseOne(state, cur, depth + 1) },
        tag_optional => .{ .optional = try parseOne(state, cur, depth + 1) },
        tag_struct => blk: {
            const n = wire.getUv(cur) catch return error.Corrupt;
            if (n > 1 << 20) return error.Corrupt; // sanity cap, hostile-input guard
            const fields = try gpa.alloc(Schema.Field, @intCast(n));
            var filled: usize = 0;
            errdefer {
                for (fields[0..filled]) |f| {
                    gpa.free(@constCast(f.name));
                    freeSchema(gpa, f.ty);
                }
                gpa.free(fields);
            }
            var pending_name: ?[]u8 = null;
            var pending_ty: ?*Schema = null;
            errdefer {
                if (pending_name) |name| gpa.free(name);
                if (pending_ty) |ty| freeSchema(gpa, ty);
            }
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const nlen = wire.getUv(cur) catch return error.Corrupt;
                if (nlen == 0 or nlen > maxSchemaName or nlen > cur.len) return error.Corrupt;
                pending_name = try gpa.dupe(u8, cur.*[0..@intCast(nlen)]);
                cur.* = cur.*[@intCast(nlen)..];
                pending_ty = try parseOne(state, cur, depth + 1);
                for (fields[0..i]) |prior| {
                    if (std.mem.eql(u8, prior.name, pending_name.?)) {
                        return error.Corrupt;
                    }
                }
                fields[i] = .{ .name = pending_name.?, .ty = pending_ty.? };
                filled += 1;
                pending_name = null;
                pending_ty = null;
            }
            break :blk .{ .@"struct" = fields };
        },
        tag_variant => blk: {
            const n = wire.getUv(cur) catch return error.Corrupt;
            if (n == 0 or n > maxSchemaNodes) return error.Corrupt;
            const cases = try gpa.alloc(Schema.Case, @intCast(n));
            var filled: usize = 0;
            errdefer {
                for (cases[0..filled]) |c| {
                    gpa.free(@constCast(c.name));
                    freeSchema(gpa, c.ty);
                }
                gpa.free(cases);
            }
            var pending_name: ?[]u8 = null;
            var pending_ty: ?*Schema = null;
            errdefer {
                if (pending_name) |name| gpa.free(name);
                if (pending_ty) |ty| freeSchema(gpa, ty);
            }
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const nlen = wire.getUv(cur) catch return error.Corrupt;
                if (nlen == 0 or nlen > maxSchemaName or nlen > cur.len) return error.Corrupt;
                pending_name = try gpa.dupe(u8, cur.*[0..@intCast(nlen)]);
                cur.* = cur.*[@intCast(nlen)..];
                pending_ty = try parseOne(state, cur, depth + 1);
                for (cases[0..i]) |prior| {
                    if (std.mem.eql(u8, prior.name, pending_name.?)) {
                        return error.Corrupt;
                    }
                }
                cases[i] = .{ .name = pending_name.?, .ty = pending_ty.? };
                filled += 1;
                pending_name = null;
                pending_ty = null;
            }
            break :blk .{ .variant = cases };
        },
        else => return error.Corrupt,
    };
    return node;
}

/// A heap-owned deep copy of `s`, freed with `freeSchema` exactly like a
/// `parseSchema` result (trivially correct BECAUSE it reuses the already-
/// verified canonicalize/parse round-trip rather than a hand-rolled second
/// tree-copy implementation — one traversal, not two). `manifest.zig`'s
/// `Manifest.addSlot` uses this to give a staged `weft.slot` declaration its
/// own owned tree, independent of whatever the caller's schema value's
/// storage duration is.
pub fn cloneSchema(gpa: Allocator, s: *const Schema) (DecodeError || Allocator.Error || SchemaValidationError)!*const Schema {
    const blob = try canonicalizeSchema(gpa, s);
    defer gpa.free(blob);
    return parseSchema(gpa, blob);
}

/// Recursively free a tree `parseSchema` produced. See that function's doc
/// for the ownership rule this depends on.
pub fn freeSchema(gpa: Allocator, schema: *const Schema) void {
    switch (schema.*) {
        .array, .optional => |elem| freeSchema(gpa, elem),
        .@"struct" => |fields| {
            for (fields) |f| {
                gpa.free(@constCast(f.name));
                freeSchema(gpa, f.ty);
            }
            gpa.free(@constCast(fields));
        },
        .variant => |cases| {
            for (cases) |c| {
                gpa.free(@constCast(c.name));
                freeSchema(gpa, c.ty);
            }
            gpa.free(@constCast(cases));
        },
        .scalar, .str, .bytes, .anchor, .range => {},
    }
    gpa.destroy(@as(*Schema, @constCast(schema)));
}

/// Deep structural equality — test/`explain` support, and how a caller
/// proves a round-trip (`parseSchema(canonicalizeSchema(s))`) reproduced
/// the original tree without relying on pointer identity.
pub fn schemaEql(a: *const Schema, b: *const Schema) bool {
    if (@as(std.meta.Tag(Schema), a.*) != @as(std.meta.Tag(Schema), b.*)) return false;
    return switch (a.*) {
        .scalar => a.scalar == b.scalar,
        .str, .bytes, .anchor, .range => true,
        .array => schemaEql(a.array, b.array),
        .optional => schemaEql(a.optional, b.optional),
        .variant => blk: {
            const ac = a.variant;
            const bc = b.variant;
            if (ac.len != bc.len) break :blk false;
            for (ac, bc) |x, y| {
                if (!std.mem.eql(u8, x.name, y.name) or !schemaEql(x.ty, y.ty)) break :blk false;
            }
            break :blk true;
        },
        .@"struct" => blk: {
            const af = a.@"struct";
            const bf = b.@"struct";
            if (af.len != bf.len) break :blk false;
            for (af, bf) |x, y| {
                if (!std.mem.eql(u8, x.name, y.name)) break :blk false;
                if (!schemaEql(x.ty, y.ty)) break :blk false;
            }
            break :blk true;
        },
    };
}

// ── Tests ─────────────────────────────────────────────────────────────

const t = std.testing;

test "schema: scalar round-trip, every Scalar kind" {
    const gpa = t.allocator;
    inline for (std.meta.fields(Scalar)) |f| {
        const sk: Scalar = @enumFromInt(f.value);
        const schema: Schema = .{ .scalar = sk };
        const value: Value = .{ .scalar = switch (sk) {
            .bool => .{ .bool = true },
            .i32 => .{ .i32 = -42 },
            .i64 => .{ .i64 = -424242 },
            .u32 => .{ .u32 = 42 },
            .u64 => .{ .u64 = 424242 },
            .f32 => .{ .f32 = 1.5 },
            .f64 => .{ .f64 = 2.5 },
        } };
        const bytes = try encode(gpa, &schema, value);
        defer gpa.free(bytes);
        try t.expectEqual(scalarWidth(sk), bytes.len);
        const cur = decodeCursor(&schema, bytes);
        switch (sk) {
            .bool => try t.expectEqual(true, try cur.asBool()),
            .i32 => try t.expectEqual(@as(i32, -42), try cur.asI32()),
            .i64 => try t.expectEqual(@as(i64, -424242), try cur.asI64()),
            .u32 => try t.expectEqual(@as(u32, 42), try cur.asU32()),
            .u64 => try t.expectEqual(@as(u64, 424242), try cur.asU64()),
            .f32 => try t.expectEqual(@as(f32, 1.5), try cur.asF32()),
            .f64 => try t.expectEqual(@as(f64, 2.5), try cur.asF64()),
        }
    }
}

test "schema: str/bytes round-trip, utf8 validated on decode" {
    const gpa = t.allocator;
    const str_schema: Schema = .str;
    const bytes1 = try encode(gpa, &str_schema, .{ .str = "hello" });
    defer gpa.free(bytes1);
    try t.expectEqualStrings("hello", try decodeCursor(&str_schema, bytes1).asStr());

    // Invalid utf8 in a `str` field traps decode (never silently passed
    // through) — construct a malformed length-prefixed payload by hand.
    const bad = [_]u8{ 1, 0xff }; // uv len=1, one invalid utf8 byte
    try t.expectError(error.Corrupt, decodeCursor(&str_schema, &bad).asStr());

    const bytes_schema: Schema = .bytes;
    const raw = [_]u8{ 0xff, 0x00, 0x80 };
    const bytes2 = try encode(gpa, &bytes_schema, .{ .bytes = &raw });
    defer gpa.free(bytes2);
    try t.expectEqualSlices(u8, &raw, try decodeCursor(&bytes_schema, bytes2).asBytes());
}

test "schema: array round-trip" {
    const gpa = t.allocator;
    const elem: Schema = .{ .scalar = .u32 };
    const schema: Schema = .{ .array = &elem };
    const vals = [_]Value{ .{ .scalar = .{ .u32 = 1 } }, .{ .scalar = .{ .u32 = 2 } }, .{ .scalar = .{ .u32 = 3 } } };
    const bytes = try encode(gpa, &schema, .{ .array = &vals });
    defer gpa.free(bytes);

    var arr = try decodeCursor(&schema, bytes).enterArray();
    try t.expectEqual(@as(usize, 3), arr.len());
    var got: [3]u32 = undefined;
    var i: usize = 0;
    while (try arr.next()) |c| : (i += 1) got[i] = try c.asU32();
    try t.expectEqualSlices(u32, &.{ 1, 2, 3 }, &got);
}

test "schema: struct round-trip, field() and iter()" {
    const gpa = t.allocator;
    const str_ty: Schema = .str;
    const u32_ty: Schema = .{ .scalar = .u32 };
    const fields = [_]Schema.Field{
        .{ .name = "text", .ty = &str_ty },
        .{ .name = "count", .ty = &u32_ty },
    };
    const schema: Schema = .{ .@"struct" = &fields };
    const vals = [_]Value{ .{ .str = "hi" }, .{ .scalar = .{ .u32 = 7 } } };
    const bytes = try encode(gpa, &schema, .{ .@"struct" = &vals });
    defer gpa.free(bytes);

    const sc = try decodeCursor(&schema, bytes).enterStruct();
    const count_cur = (try sc.field("count")).?;
    try t.expectEqual(@as(u32, 7), try count_cur.asU32());
    const text_cur = (try sc.field("text")).?;
    try t.expectEqualStrings("hi", try text_cur.asStr());
    try t.expectEqual(@as(?Cursor, null), try sc.field("nope"));

    var it = sc.iter();
    const first = (try it.next()).?;
    try t.expectEqualStrings("text", first.name);
    const second = (try it.next()).?;
    try t.expectEqualStrings("count", second.name);
    try t.expect((try it.next()) == null);
}

test "schema: optional present/absent round-trip" {
    const gpa = t.allocator;
    const inner: Schema = .str;
    const schema: Schema = .{ .optional = &inner };

    const present_val: Value = .{ .str = "yo" };
    const present = try encode(gpa, &schema, .{ .optional = &present_val });
    defer gpa.free(present);
    const pc = (try decodeCursor(&schema, present).enterOptional()).?;
    try t.expectEqualStrings("yo", try pc.asStr());

    const absent = try encode(gpa, &schema, .{ .optional = null });
    defer gpa.free(absent);
    try t.expectEqual(@as(?Cursor, null), try decodeCursor(&schema, absent).enterOptional());
    try t.expectEqual(@as(usize, 1), absent.len);
}

test "schema: variant encodes a bounded tag and selected payload" {
    const gpa = t.allocator;
    const text_ty: Schema = .str;
    const count_ty: Schema = .{ .scalar = .u32 };
    const cases = [_]Schema.Case{
        .{ .name = "text", .ty = &text_ty },
        .{ .name = "count", .ty = &count_ty },
    };
    const schema: Schema = .{ .variant = &cases };

    const text_value: Value = .{ .str = "hello" };
    const text_bytes = try encode(gpa, &schema, .{ .variant = .{ .tag = 0, .payload = &text_value } });
    defer gpa.free(text_bytes);
    try t.expectEqualSlices(u8, &.{ 0, 5, 'h', 'e', 'l', 'l', 'o' }, text_bytes);
    const text_cur = try decodeCursor(&schema, text_bytes).enterVariant();
    try t.expectEqual(@as(usize, 0), text_cur.tag);
    try t.expectEqualStrings("text", text_cur.caseName());
    try t.expectEqualStrings("hello", try text_cur.selected().asStr());

    const count_value: Value = .{ .scalar = .{ .u32 = 42 } };
    const count_bytes = try encode(gpa, &schema, .{ .variant = .{ .tag = 1, .payload = &count_value } });
    defer gpa.free(count_bytes);
    try t.expectEqualSlices(u8, &.{ 1, 42, 0, 0, 0 }, count_bytes);
    const count_cur = try decodeCursor(&schema, count_bytes).enterVariant();
    try t.expectEqual(@as(usize, 1), count_cur.tag);
    try t.expectEqualStrings("count", count_cur.caseName());
    try t.expectEqual(@as(u32, 42), try count_cur.selected().asU32());

    try t.expectError(error.SchemaMismatch, encode(gpa, &schema, .{ .variant = .{ .tag = 2, .payload = &count_value } }));
    try t.expectError(error.SchemaMismatch, encode(gpa, &schema, .{ .variant = .{ .tag = 0, .payload = &count_value } }));
}

test "schema: variant walks selected nested marks and refuses unknown/truncated tags" {
    const gpa = t.allocator;
    const range_ty: Schema = .range;
    const cases = [_]Schema.Case{.{ .name = "location", .ty = &range_ty }};
    const schema: Schema = .{ .variant = &cases };
    const value: Value = .{ .range = .{ .version = "stale", .start = 4, .end = 9 } };
    const bytes = try encode(gpa, &schema, .{ .variant = .{ .tag = 0, .payload = &value } });
    defer gpa.free(bytes);

    const Ctx = struct { version: []const u8 };
    var ctx: Ctx = .{ .version = "fresh" };
    const rewritten = try walk(gpa, &schema, bytes, .{
        .ctx = &ctx,
        .on_range = struct {
            fn cb(c: ?*anyopaque, r: RangeWire) []const u8 {
                _ = r;
                return @as(*Ctx, @ptrCast(@alignCast(c.?))).version;
            }
        }.cb,
    });
    defer gpa.free(rewritten);
    const variant = try decodeCursor(&schema, rewritten).enterVariant();
    try t.expectEqualStrings("fresh", (try variant.selected().asRange()).version);

    try t.expectError(error.Corrupt, decodeCursor(&schema, &.{ 1, 0 }).enterVariant());
    try t.expectError(error.Corrupt, (try decodeCursor(&schema, &.{0}).enterVariant()).selected().asRange());
    try t.expectError(error.Corrupt, walk(gpa, &schema, &.{ 2, 0 }, .{}));
}

test "schema: variant canonicalization preserves case metadata and validates it" {
    const gpa = t.allocator;
    const str_ty: Schema = .str;
    const u32_ty: Schema = .{ .scalar = .u32 };
    const cases = [_]Schema.Case{
        .{ .name = "message", .ty = &str_ty },
        .{ .name = "code", .ty = &u32_ty },
    };
    const original: Schema = .{ .variant = &cases };
    const blob = try canonicalizeSchema(gpa, &original);
    defer gpa.free(blob);
    try t.expectEqual(tag_variant, blob[0]);
    const parsed = try parseSchema(gpa, blob);
    defer freeSchema(gpa, parsed);
    try t.expect(schemaEql(&original, parsed));

    const duplicate = [_]Schema.Case{
        .{ .name = "same", .ty = &str_ty },
        .{ .name = "same", .ty = &u32_ty },
    };
    const invalid_duplicate: Schema = .{ .variant = &duplicate };
    try t.expectError(error.InvalidSchema, validateSchema(&invalid_duplicate));
    try t.expectError(error.InvalidSchema, canonicalizeSchema(gpa, &invalid_duplicate));

    const empty: Schema = .{ .variant = &.{} };
    try t.expectError(error.InvalidSchema, validateSchema(&empty));
    try t.expectError(error.Corrupt, parseSchema(gpa, &.{ tag_variant, 0 }));
    // A valid blob followed by bytes is not another valid canonical schema.
    try t.expectError(error.Corrupt, parseSchema(gpa, &.{ tag_variant, 1, 1, 'x', tag_str, 255 }));
}

test "schema: anchor/range round-trip (the two schema marks)" {
    const gpa = t.allocator;
    const anchor_schema: Schema = .anchor;
    const a_bytes = try encode(gpa, &anchor_schema, .{ .anchor = .{ .agent = "alice", .seq = 9, .side = 1 } });
    defer gpa.free(a_bytes);
    const a = try decodeCursor(&anchor_schema, a_bytes).asAnchor();
    try t.expectEqualStrings("alice", a.agent);
    try t.expectEqual(@as(u64, 9), a.seq);
    try t.expectEqual(@as(u8, 1), a.side);

    const range_schema: Schema = .range;
    const r_bytes = try encode(gpa, &range_schema, .{ .range = .{ .version = "v1", .start = 3, .end = 7 } });
    defer gpa.free(r_bytes);
    const r = try decodeCursor(&range_schema, r_bytes).asRange();
    try t.expectEqualStrings("v1", r.version);
    try t.expectEqual(@as(u64, 3), r.start);
    try t.expectEqual(@as(u64, 7), r.end);
}

test "schema: encode rejects a value that doesn't match the schema's shape" {
    const gpa = t.allocator;
    const schema: Schema = .{ .scalar = .u32 };
    try t.expectError(error.SchemaMismatch, encode(gpa, &schema, .{ .str = "nope" }));
    const str_schema: Schema = .str;
    try t.expectError(error.SchemaMismatch, encode(gpa, &str_schema, .{ .scalar = .{ .u32 = 1 } }));
}

test "schema: evolution — a struct gains a trailing field; the OLD schema tolerates a NEW payload" {
    const gpa = t.allocator;
    const str_ty: Schema = .str;
    const u32_ty: Schema = .{ .scalar = .u32 };
    // The v2 producer's schema: text, count, extra (appended at the end —
    // §2.3's only legal evolution).
    const v2_fields = [_]Schema.Field{
        .{ .name = "text", .ty = &str_ty },
        .{ .name = "count", .ty = &u32_ty },
        .{ .name = "extra", .ty = &u32_ty },
    };
    const v2_schema: Schema = .{ .@"struct" = &v2_fields };
    const v2_vals = [_]Value{ .{ .str = "hi" }, .{ .scalar = .{ .u32 = 7 } }, .{ .scalar = .{ .u32 = 99 } } };
    const v2_bytes = try encode(gpa, &v2_schema, .{ .@"struct" = &v2_vals });
    defer gpa.free(v2_bytes);

    // The v1 (OLD) consumer's schema: only text, count.
    const v1_fields = [_]Schema.Field{
        .{ .name = "text", .ty = &str_ty },
        .{ .name = "count", .ty = &u32_ty },
    };
    const v1_schema: Schema = .{ .@"struct" = &v1_fields };

    // Decoding the NEW (v2) payload against the OLD (v1) schema succeeds —
    // the trailing "extra" field is simply never read.
    const sc = try decodeCursor(&v1_schema, v2_bytes).enterStruct();
    try t.expectEqualStrings("hi", try (try sc.field("text")).?.asStr());
    try t.expectEqual(@as(u32, 7), try (try sc.field("count")).?.asU32());
    try t.expectEqual(@as(?Cursor, null), try sc.field("extra")); // v1 schema doesn't know it
}

test "schema: evolution — a NEWER schema reading an OLDER payload refuses loudly, no silent third result" {
    const gpa = t.allocator;
    const str_ty: Schema = .str;
    const u32_ty: Schema = .{ .scalar = .u32 };
    // v1 (OLD) producer: only text, count.
    const v1_fields = [_]Schema.Field{
        .{ .name = "text", .ty = &str_ty },
        .{ .name = "count", .ty = &u32_ty },
    };
    const v1_schema: Schema = .{ .@"struct" = &v1_fields };
    const v1_vals = [_]Value{ .{ .str = "hi" }, .{ .scalar = .{ .u32 = 7 } } };
    const v1_bytes = try encode(gpa, &v1_schema, .{ .@"struct" = &v1_vals });
    defer gpa.free(v1_bytes);

    // v2 (NEW) consumer requires a trailing, non-optional "extra" field the
    // v1 payload never wrote.
    const v2_fields = [_]Schema.Field{
        .{ .name = "text", .ty = &str_ty },
        .{ .name = "count", .ty = &u32_ty },
        .{ .name = "extra", .ty = &u32_ty },
    };
    const v2_schema: Schema = .{ .@"struct" = &v2_fields };
    const sc = try decodeCursor(&v2_schema, v1_bytes).enterStruct();
    try t.expectEqualStrings("hi", try (try sc.field("text")).?.asStr());
    try t.expectError(error.Corrupt, (try sc.field("extra")).?.asU32());

    // The `optional`-field escape hatch §2.3 names: the SAME skew, but
    // "extra" is optional — a fresh consumer reads an absent field as
    // absent instead of refusing.
    const opt_fields = [_]Schema.Field{
        .{ .name = "text", .ty = &str_ty },
        .{ .name = "count", .ty = &u32_ty },
        .{ .name = "extra", .ty = &(Schema{ .optional = &u32_ty }) },
    };
    const opt_schema: Schema = .{ .@"struct" = &opt_fields };
    // v1's raw bytes don't have the presence byte at all — a truly OLD
    // producer never wrote the field, so there is nothing to read; the
    // legal move here is the SLOT NAME versioning §2.3 describes ("a
    // consumer newer than the payload applies trailing tolerance" only
    // covers bytes that exist). This second half proves the CONVERSE:
    // when a v1.5 producer DOES know about `optional extra` and writes an
    // explicit presence byte, the v2 consumer decodes it cleanly either way.
    const v15_fields = [_]Schema.Field{
        .{ .name = "text", .ty = &str_ty },
        .{ .name = "count", .ty = &u32_ty },
        .{ .name = "extra", .ty = &(Schema{ .optional = &u32_ty }) },
    };
    const v15_schema: Schema = .{ .@"struct" = &v15_fields };
    const v15_bytes = try encode(gpa, &v15_schema, .{ .@"struct" = &.{ .{ .str = "hi" }, .{ .scalar = .{ .u32 = 7 } }, .{ .optional = null } } });
    defer gpa.free(v15_bytes);
    const sc2 = try decodeCursor(&opt_schema, v15_bytes).enterStruct();
    try t.expectEqual(@as(?Cursor, null), try (try sc2.field("extra")).?.enterOptional());
}

test "schema: hostile input — truncated/garbage payloads trap (Corrupt), never a slice panic" {
    const str_schema: Schema = .str;
    try t.expectError(error.Corrupt, decodeCursor(&str_schema, &.{}).asStr());
    try t.expectError(error.Corrupt, decodeCursor(&str_schema, &.{200}).asStr()); // uv-len says 200, zero bytes follow

    const u32_schema: Schema = .{ .scalar = .u32 };
    try t.expectError(error.Corrupt, decodeCursor(&u32_schema, &.{ 1, 2 }).asU32()); // needs 4 bytes

    const elem: Schema = .{ .scalar = .u32 };
    const arr_schema: Schema = .{ .array = &elem };
    // uv count = 5, but only one element's worth of bytes follow.
    var arr = try decodeCursor(&arr_schema, &.{ 5, 1, 0, 0, 0 }).enterArray();
    try t.expect((try arr.next()) != null);
    try t.expectError(error.Corrupt, arr.next());

    const anchor_schema: Schema = .anchor;
    try t.expectError(error.Corrupt, decodeCursor(&anchor_schema, &.{}).asAnchor());
    const range_schema: Schema = .range;
    try t.expectError(error.Corrupt, decodeCursor(&range_schema, &.{}).asRange());

    // A garbage top-level tag never panics `parseSchema` either.
    const gpa = t.allocator;
    try t.expectError(error.Corrupt, parseSchema(gpa, &.{255}));
}

test "schema: versioned wire prefix round-trips (SchemaRef, §2.3)" {
    const gpa = t.allocator;
    const schema: Schema = .{ .scalar = .u32 };
    const bytes = try encodeVersioned(gpa, 7, &schema, .{ .scalar = .{ .u32 = 42 } });
    defer gpa.free(bytes);
    const split = try splitVersion(bytes);
    try t.expectEqual(@as(u32, 7), split.version);
    try t.expectEqual(@as(u32, 42), try decodeCursor(&schema, split.rest).asU32());
}

test "schema: walk — on_range rewrites the version, on_anchor is read-only" {
    const gpa = t.allocator;
    const str_ty: Schema = .str;
    const range_ty: Schema = .range;
    const anchor_ty: Schema = .anchor;
    const fields = [_]Schema.Field{
        .{ .name = "label", .ty = &str_ty },
        .{ .name = "loc", .ty = &range_ty },
        .{ .name = "where", .ty = &anchor_ty },
    };
    const schema: Schema = .{ .@"struct" = &fields };
    const vals = [_]Value{
        .{ .str = "seg" },
        .{ .range = .{ .version = "stale-v1", .start = 2, .end = 5 } },
        .{ .anchor = .{ .agent = "bob", .seq = 3, .side = 0 } },
    };
    const bytes = try encode(gpa, &schema, .{ .@"struct" = &vals });
    defer gpa.free(bytes);

    var seen_anchor: ?AnchorWire = null;
    const Ctx = struct { fired: []const u8 };
    var ctx: Ctx = .{ .fired = "fresh-v7" };
    const rewritten = try walk(gpa, &schema, bytes, .{
        .ctx = &ctx,
        .on_range = struct {
            fn cb(c: ?*anyopaque, r: RangeWire) []const u8 {
                _ = r;
                const self: *Ctx = @ptrCast(@alignCast(c.?));
                return self.fired;
            }
        }.cb,
        .on_anchor = struct {
            fn cb(c: ?*anyopaque, a: AnchorWire) void {
                _ = c;
                seen_anchor_slot = a;
            }
        }.cb,
    });
    _ = &seen_anchor;
    defer gpa.free(rewritten);

    const sc = try decodeCursor(&schema, rewritten).enterStruct();
    try t.expectEqualStrings("seg", try (try sc.field("label")).?.asStr());
    const loc = try (try sc.field("loc")).?.asRange();
    try t.expectEqualStrings("fresh-v7", loc.version);
    try t.expectEqual(@as(u64, 2), loc.start);
    try t.expectEqual(@as(u64, 5), loc.end);
    const where = try (try sc.field("where")).?.asAnchor();
    try t.expectEqualStrings("bob", where.agent);
    try t.expectEqual(@as(u64, 3), where.seq);
}

// A module-level slot the anchor callback above writes through — Zig
// closures can't capture by reference into a plain `*const fn`, so the test
// uses a file-scope var the same way other test files in this repo stash
// callback-observed state (kept `threadlocal`-free: `zig build test` runs
// this file's tests single-threaded within their own process, matching
// every other pure-function test module here).
var seen_anchor_slot: AnchorWire = undefined;

test "schema: canonicalizeSchema/parseSchema round-trip — the meta-schema self-hosting the SAME wire primitives" {
    const gpa = t.allocator;
    const str_ty: Schema = .str;
    const u32_ty: Schema = .{ .scalar = .u32 };
    const anchor_ty: Schema = .anchor;
    const opt_ty: Schema = .{ .optional = &str_ty };
    const arr_ty: Schema = .{ .array = &u32_ty };
    const fields = [_]Schema.Field{
        .{ .name = "text", .ty = &str_ty },
        .{ .name = "count", .ty = &u32_ty },
        .{ .name = "where", .ty = &anchor_ty },
        .{ .name = "doc", .ty = &opt_ty },
        .{ .name = "tags", .ty = &arr_ty },
    };
    const original: Schema = .{ .@"struct" = &fields };

    const blob1 = try canonicalizeSchema(gpa, &original);
    defer gpa.free(blob1);
    const parsed = try parseSchema(gpa, blob1);
    defer freeSchema(gpa, parsed);
    try t.expect(schemaEql(&original, parsed));

    // Re-canonicalizing the PARSED tree reproduces the identical blob —
    // "byte-identical for byte-identical trees," the determinism §2.2 form
    // 2 promises.
    const blob2 = try canonicalizeSchema(gpa, parsed);
    defer gpa.free(blob2);
    try t.expectEqualSlices(u8, blob1, blob2);
}

test "schema: cloneSchema deep-copies independent of the source tree's storage" {
    const gpa = t.allocator;
    var original: Schema = .{ .scalar = .u32 };
    const cloned = try cloneSchema(gpa, &original);
    defer freeSchema(gpa, cloned);
    try t.expect(schemaEql(&original, cloned));
    try t.expect(@intFromPtr(cloned) != @intFromPtr(&original)); // a real, independent copy
    original = .{ .scalar = .bool }; // mutating the source doesn't touch the clone
    try t.expectEqual(Scalar.u32, cloned.scalar);
}

test "schema: parseSchema hostile input — truncated struct field count/name never over-reads" {
    const gpa = t.allocator;
    // tag_struct, uv fields=200, nothing else follows.
    try t.expectError(error.Corrupt, parseSchema(gpa, &.{ tag_struct, 200 }));
    // tag_struct, uv fields=1, uv name_len=50, no name bytes follow.
    try t.expectError(error.Corrupt, parseSchema(gpa, &.{ tag_struct, 1, 50 }));
    // tag_array with no element tag following.
    try t.expectError(error.Corrupt, parseSchema(gpa, &.{tag_array}));
}

test {
    std.testing.refAllDecls(@This());
}
