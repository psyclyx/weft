//! rowkey — a row's IDENTITY as a key, encoded and parsed by REFLECTION.
//!
//! A projection producer chooses its rows' keys, and a key has to survive the
//! round trip: mint it when the row is published, read it back when a verb
//! acts. `files` gets this for free — its key is a scene node id, one integer —
//! but a producer whose identity is STRUCTURED does not. git's row is a
//! section, or a section and a path, or a section and a path and a hunk
//! ordinal, or a commit hash.
//!
//! So git wrote a codec, and with it a comment:
//!
//!   > The path goes LAST in the file and hunk forms so a path containing a
//!   > colon cannot be confused for a separator — everything before it is
//!   > fixed-arity.
//!
//! That is a real rule and a real hazard — a filename with a colon in it is
//! perfectly legal, and a key that put the path first would parse a different
//! row than the one it named. But it was a rule kept by REMEMBERING it. Add a
//! variant with two paths, or put the ordinal after the path, and nothing
//! says a word until someone opens a file with a colon in its name.
//!
//! Here the rule is CHECKED, at comptime, from the shape of the record: at most
//! one variable-length field per variant, and it must be last. A key that could
//! be ambiguous does not compile.
//!
//! WHAT A PRODUCER SAYS: a tagged union whose payloads are plain structs of
//! enums, integers, and at most one trailing `[]const u8`. What it never writes
//! is a parser.

const std = @import("std");

/// The separator. Fixed-arity fields never contain it (an enum's name and a
/// decimal integer cannot), and the one field that may is last, so it is never
/// searched for past its own boundary.
const sep = ':';

pub fn Codec(comptime T: type) type {
    const info = switch (@typeInfo(T)) {
        .@"union" => |u| u,
        else => @compileError("rowkey.Codec expects a tagged union, found " ++ @typeName(T)),
    };
    if (info.tag_type == null) @compileError("rowkey.Codec expects a TAGGED union: " ++ @typeName(T));
    comptime checkShape(T, info);

    return struct {
        /// Encode `value` into `out`. Empty when it does not fit, which a
        /// caller treats as "this row has no key" — the same standing as a row
        /// it did not mint, and the only honest answer when the identity was
        /// truncated.
        pub fn encode(value: T, out: []u8) []const u8 {
            var w: usize = 0;
            switch (value) {
                inline else => |payload, tag| {
                    w = write(out, w, @tagName(tag)) orelse return "";
                    const P = @TypeOf(payload);
                    if (P != void) {
                        inline for (@typeInfo(P).@"struct".fields) |f| {
                            w = write(out, w, &[_]u8{sep}) orelse return "";
                            w = writeField(out, w, f.type, @field(payload, f.name)) orelse return "";
                        }
                    }
                },
            }
            return out[0..w];
        }

        /// Parse `key` back. Null for a key this producer did not mint, or one
        /// whose fields no longer parse — a row it cannot NAME is a row it must
        /// not act on, which is why this refuses rather than approximating.
        ///
        /// Any returned slice BORROWS `key`.
        pub fn decode(key: []const u8) ?T {
            const end = std.mem.indexOfScalar(u8, key, sep) orelse key.len;
            const tag_name = key[0..end];
            var rest: []const u8 = if (end == key.len) "" else key[end + 1 ..];
            inline for (info.fields) |variant| {
                if (std.mem.eql(u8, variant.name, tag_name)) {
                    if (variant.type == void) {
                        return if (end == key.len) @unionInit(T, variant.name, {}) else null;
                    }
                    var payload: variant.type = undefined;
                    const fields = @typeInfo(variant.type).@"struct".fields;
                    inline for (fields, 0..) |f, i| {
                        const last = i + 1 == fields.len;
                        const token = if (last and isVariable(f.type))
                            rest
                        else blk: {
                            const cut = std.mem.indexOfScalar(u8, rest, sep) orelse
                                (if (last) rest.len else return null);
                            const token_bytes = rest[0..cut];
                            rest = if (cut == rest.len) "" else rest[cut + 1 ..];
                            break :blk token_bytes;
                        };
                        @field(payload, f.name) = readField(f.type, token) orelse return null;
                    }
                    return @unionInit(T, variant.name, payload);
                }
            }
            return null;
        }
    };
}

fn checkShape(comptime T: type, comptime info: std.builtin.Type.Union) void {
    for (info.fields) |variant| {
        if (variant.type == void) continue;
        const s = switch (@typeInfo(variant.type)) {
            .@"struct" => |s| s,
            else => @compileError("rowkey: variant '" ++ variant.name ++ "' of " ++
                @typeName(T) ++ " must be a struct or void"),
        };
        for (s.fields, 0..) |f, i| {
            if (!isVariable(f.type)) {
                if (!isFixed(f.type)) @compileError("rowkey: field '" ++ f.name ++ "' of variant '" ++
                    variant.name ++ "' is " ++ @typeName(f.type) ++
                    "; a key field must be an enum, an unsigned integer, or []const u8");
                continue;
            }
            // THE RULE, CHECKED. A variable-length field swallows everything
            // after it, so anything following would be parsed out of ITS bytes
            // — which is how a path containing the separator names the wrong
            // row. Last, and only one.
            if (i + 1 != s.fields.len) @compileError("rowkey: variable-length field '" ++ f.name ++
                "' of variant '" ++ variant.name ++ "' must be LAST — a field after it would be" ++
                " parsed out of its own bytes whenever it contains a '" ++ [_]u8{sep} ++ "'");
        }
    }
}

fn isVariable(comptime F: type) bool {
    return F == []const u8;
}

fn isFixed(comptime F: type) bool {
    return switch (@typeInfo(F)) {
        .@"enum" => true,
        .int => |i| i.signedness == .unsigned,
        else => false,
    };
}

fn write(out: []u8, at: usize, bytes: []const u8) ?usize {
    if (at + bytes.len > out.len) return null;
    @memcpy(out[at..][0..bytes.len], bytes);
    return at + bytes.len;
}

fn writeField(out: []u8, at: usize, comptime F: type, value: F) ?usize {
    if (comptime isVariable(F)) return write(out, at, value);
    return switch (@typeInfo(F)) {
        .@"enum" => write(out, at, @tagName(value)),
        .int => blk: {
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch break :blk null;
            break :blk write(out, at, s);
        },
        else => unreachable,
    };
}

fn readField(comptime F: type, token: []const u8) ?F {
    if (comptime isVariable(F)) return token;
    return switch (@typeInfo(F)) {
        .@"enum" => std.meta.stringToEnum(F, token),
        .int => std.fmt.parseInt(F, token, 10) catch null,
        else => unreachable,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────

const t = std.testing;

const Section = enum { untracked, unstaged, staged };

const Row = union(enum) {
    section: struct { section: Section },
    file: struct { section: Section, path: []const u8 },
    hunk: struct { section: Section, ord: usize, path: []const u8 },
    commit: struct { hash: []const u8 },
    root,
};

const codec = Codec(Row);

test "rowkey: a structured identity round-trips" {
    var buf: [512]u8 = undefined;

    const file: Row = .{ .file = .{ .section = .staged, .path = "src/main.zig" } };
    const key = codec.encode(file, &buf);
    try t.expectEqualStrings("file:staged:src/main.zig", key);
    const back = codec.decode(key).?;
    try t.expectEqual(Section.staged, back.file.section);
    try t.expectEqualStrings("src/main.zig", back.file.path);

    const hunk: Row = .{ .hunk = .{ .section = .unstaged, .ord = 3, .path = "a.txt" } };
    try t.expectEqualStrings("hunk:unstaged:3:a.txt", codec.encode(hunk, &buf));
    const hb = codec.decode(codec.encode(hunk, &buf)).?;
    try t.expectEqual(@as(usize, 3), hb.hunk.ord);
    try t.expectEqualStrings("a.txt", hb.hunk.path);

    // A variant with no payload at all is just its name.
    try t.expectEqualStrings("root", codec.encode(.root, &buf));
    try t.expect(codec.decode("root").? == .root);
}

test "rowkey: a separator INSIDE the trailing field is part of it" {
    // THE HAZARD THIS EXISTS FOR. `weird:name.txt` is a perfectly legal
    // filename, and a codec that searched for the separator would parse the
    // key of a different row — silently, and only for people with such files.
    var buf: [512]u8 = undefined;
    const row: Row = .{ .file = .{ .section = .untracked, .path = "weird:name:with:colons.txt" } };
    const key = codec.encode(row, &buf);
    const back = codec.decode(key).?;
    try t.expectEqual(Section.untracked, back.file.section);
    try t.expectEqualStrings("weird:name:with:colons.txt", back.file.path);
}

test "rowkey: a key it did not mint, or one that no longer parses, is refused" {
    // Another producer's key, an unknown enum member, a missing field, a
    // non-numeric ordinal. A row this cannot NAME is one it must not act on,
    // so every one of these is null rather than a partly-filled identity.
    try t.expect(codec.decode("") == null);
    try t.expect(codec.decode("42") == null); // files' key, not git's
    try t.expect(codec.decode("file:nosuchsection:a.txt") == null);
    try t.expect(codec.decode("file:staged") == null); // no path field
    try t.expect(codec.decode("hunk:staged:notanumber:a.txt") == null);
    try t.expect(codec.decode("root:extra") == null);
}

test "rowkey: a key that does not fit is no key" {
    // Truncation would produce a key that names a DIFFERENT row — a path cut
    // mid-way is another path. Refusing is the only honest answer.
    var small: [8]u8 = undefined;
    const row: Row = .{ .file = .{ .section = .staged, .path = "a-long-path.txt" } };
    try t.expectEqualStrings("", codec.encode(row, &small));
}
