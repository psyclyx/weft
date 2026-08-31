//! Buffer introspection: walk the open buffers by index and read what each one
//! IS — id, name, active/read-only, backing path, dirty flag, language, size,
//! and the projection it represents.
//!
//! **About a buffer that is not the active one.** That is the whole point of
//! this file, and the gap it closes. `wl_path` and `wl_byte_len` (`edit.zig`)
//! answer only about the entry a call is dispatched in, so a plugin listing
//! buffers could show a name and a read-only flag and nothing else — it could
//! not say which of them had unsaved edits, what any of them was, or where any
//! of them came from. Every door here takes an index and answers about THAT
//! entry.
//!
//! **Two shapes, written once.** Every indexed door is either "index → int"
//! or "index → bytes", and each used to carry its own copy of the
//! walk-then-bail dance. `intDoor`/`boolDoor`/`bytesDoor` below hold that
//! once, so a body is the question it answers and nothing else, and a new
//! door cannot forget what a closed index means.
//!
//! The bodies take `anytype` for the principal, exactly like `edit.zig`'s
//! shared read doors: they use only `activeCtx()` and `gpa`, so they are one
//! implementation the JS plane can wrap when it wants these, and they are
//! callable from a test with no wasm instance behind them.
//!
//! Ungated, all of them: these are reads that carry no authority — no perm,
//! no trap, no mutation. What a plugin may DO with a buffer is decided at the
//! doors that act, not here.

const std = @import("std");
const wasm = @import("../wasm.zig");
const Buffers = @import("../Buffers.zig");
const action = @import("../action.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

/// The i-th open buffer, or null. An `O(i)` walk over `Buffers.slots`, which
/// holds holes for closed entries — deliberately NOT memoized: a pick over
/// every buffer is built once at open, over tens of entries, and a cursor
/// cache would be core state earning nothing measurable. If a profile ever
/// says otherwise, `Buffers` is where a dense view belongs, not here.
pub fn bufferAtIndex(p: anytype, i: usize) ?*Buffers.Buffer {
    var it = p.activeCtx().buffers.iterator();
    var j: usize = 0;
    while (it.next()) |b| : (j += 1) if (j == i) return b;
    return null;
}

// ── The bodies ───────────────────────────────────────────────────────

pub fn idOf(_: anytype, b: *Buffers.Buffer) i32 {
    return @intCast(b.id);
}

pub fn nameOf(_: anytype, b: *Buffers.Buffer) ?[]const u8 {
    return b.name;
}

pub fn isActive(p: anytype, b: *Buffers.Buffer) bool {
    return b == p.activeCtx().buffers.active();
}

pub fn isReadOnly(_: anytype, b: *Buffers.Buffer) bool {
    return b.read_only;
}

/// The entry's file backing — `edit.zig`'s `wl_path` generalized off the
/// active entry. Null for an entry that holds no text, or holds text no file
/// backs (a scratch, a projection).
pub fn pathOf(_: anytype, b: *Buffers.Buffer) ?[]const u8 {
    return (b.textEditor() orelse return null).backingPath();
}

/// Whether closing this entry would drop edits its file never received.
///
/// `Buffer.hasUnsavedFile` already decides the one thing that would otherwise
/// get re-decided here, and it is not re-decided: a TOOL PROJECTION is never
/// dirty, because a projection has no file to write. So this door cannot be
/// used to mark the git status buffer "unsaved", and nothing downstream has
/// to remember that as a rule. -1 on the allocation failure path, so
/// "unknown" stays distinguishable from "clean".
pub fn dirtyOf(p: anytype, b: *Buffers.Buffer) i32 {
    const dirty = b.hasUnsavedFile(p.gpa) catch return -1;
    return if (dirty) 1 else 0;
}

/// The entry's language, `action.langOfName`'s output (an extension sans
/// dot). DERIVED at the door rather than stored, and derived by the same
/// function `Facts.lang` and every `.lang` predicate use — so a guest
/// annotating a row and a provider matching on that row cannot disagree
/// about what language it is.
pub fn langOf(_: anytype, b: *Buffers.Buffer) ?[]const u8 {
    return action.langOfName(b.name);
}

/// The entry's document length. -1 for an entry that holds no text (a
/// semantic view) — `edit.zig`'s `wl_byte_len` answers 0 there, because for
/// the ACTIVE entry "empty" is the useful lie; across a list it is not.
pub fn byteLenOf(_: anytype, b: *Buffers.Buffer) i32 {
    const ed = b.textEditor() orelse return -1;
    return @intCast(ed.text().byteLen());
}

/// The projection this entry represents (`files`, `git`), or 0 bytes for a
/// plain entry. What lets a reader tell a file from a projection BEFORE it
/// says anything about either.
pub fn toolOf(_: anytype, b: *Buffers.Buffer) ?[]const u8 {
    return b.tool;
}

// ── The wasm trampolines ─────────────────────────────────────────────

/// `wl_buffer_<x>(i) -> i32`: resolve the index, else -1.
fn intDoor(comptime body: anytype) wasm.Linker.HostFn {
    return indexedInt(-1, body);
}

/// `wl_buffer_<x>(i) -> u32`: a PREDICATE about the i-th buffer. Its missing
/// answer is 0, not -1, and the difference is not cosmetic: these two declare
/// `u32` results and their guest shims read them as `!= 0`, so a -1 would
/// make "no such buffer" report TRUE. A predicate about a buffer that isn't
/// there is false.
fn boolDoor(comptime body: anytype) wasm.Linker.HostFn {
    return indexedInt(0, struct {
        fn f(p: *WasmPlugin, b: *Buffers.Buffer) i32 {
            return if (body(p, b)) 1 else 0;
        }
    }.f);
}

fn indexedInt(comptime missing: i32, comptime body: anytype) wasm.Linker.HostFn {
    return struct {
        fn f(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
            _ = caller;
            const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
            const b = bufferAtIndex(p, @intCast(args[0])) orelse {
                results[0] = missing;
                return;
            };
            results[0] = body(p, b);
        }
    }.f;
}

/// `wl_buffer_<x>(i, ptr, cap) -> i32`: resolve the index and write the
/// answer into guest memory, else -1. An answer a buffer simply does not have
/// (an unnamed entry's path) is ALSO -1 — "no such buffer" and "no such fact"
/// are both "nothing to read here", and a guest that cares can ask `count`.
fn bytesDoor(comptime body: anytype) wasm.Linker.HostFn {
    return struct {
        fn f(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
            const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
            const b = bufferAtIndex(p, @intCast(args[0])) orelse {
                results[0] = -1;
                return;
            };
            const bytes = body(p, b) orelse {
                results[0] = -1;
                return;
            };
            results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), bytes) catch 0);
        }
    }.f;
}

pub fn hBufferCount(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(p.activeCtx().buffers.count());
}

pub const hBufferId = intDoor(idOf);
pub const hBufferName = bytesDoor(nameOf);
pub const hBufferActive = boolDoor(isActive);
pub const hBufferReadonly = boolDoor(isReadOnly);
pub const hBufferPath = bytesDoor(pathOf);
pub const hBufferDirty = intDoor(dirtyOf);
pub const hBufferLang = bytesDoor(langOf);
pub const hBufferByteLen = intDoor(byteLenOf);
pub const hBufferTool = bytesDoor(toolOf);

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;
const command = @import("../command.zig");
const TestHost = @import("../TestHost.zig");

/// The minimal principal the bodies accept — they duck-type over
/// `activeCtx()` and `gpa` (see this file's module doc), so a test needs no
/// wasm instance and no guest behind it. Same construction as `fs.zig`'s
/// `TestPrincipal`.
const TestPrincipal = struct {
    gpa: std.mem.Allocator,
    ctx: *command.Context,
    fn activeCtx(self: *TestPrincipal) *command.Context {
        return self.ctx;
    }
};

test "buffer introspection answers about a buffer that is NOT the active one" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);
    var id: TestPrincipal = .{ .gpa = gpa, .ctx = &host.ctx };

    // Two entries. The SECOND holds the interesting facts; the FIRST stays
    // active throughout, which is the whole assertion — before these doors
    // existed every one of these questions silently answered about buffer 0.
    const other = try host.ctx.buffers.create(gpa, "other.zig");
    const b1 = host.ctx.buffers.get(other).?;
    try b1.textEditor().?.insertText(gpa, "fn main() void {}");

    try t.expectEqual(@as(usize, 2), host.ctx.buffers.count());
    try t.expect(isActive(&id, bufferAtIndex(&id, 0).?));
    try t.expect(!isActive(&id, bufferAtIndex(&id, 1).?));

    const b = bufferAtIndex(&id, 1).?;
    try t.expectEqualStrings("other.zig", nameOf(&id, b).?);
    try t.expectEqualStrings("zig", langOf(&id, b).?);
    try t.expectEqual(@as(i32, "fn main() void {}".len), byteLenOf(&id, b));
    // Never saved, so its edits are edits no file received.
    try t.expectEqual(@as(i32, 1), dirtyOf(&id, b));
    // No file backs it and it is not a projection.
    try t.expect(pathOf(&id, b) == null);
    try t.expectEqualStrings("", toolOf(&id, b).?);

    // The active entry is still answerable, and answers about ITSELF.
    const b0 = bufferAtIndex(&id, 0).?;
    try t.expectEqual(@as(i32, 0), byteLenOf(&id, b0));
    try t.expectEqualStrings("", langOf(&id, b0).?);
}

test "a tool projection is never dirty, and says what it is" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);
    var id: TestPrincipal = .{ .gpa = gpa, .ctx = &host.ctx };

    const gid = try host.ctx.buffers.create(gpa, "*git-status*");
    const b = host.ctx.buffers.get(gid).?;
    try b.setTool(gpa, "git");
    try b.textEditor().?.insertText(gpa, "M  src/core/file.zig");

    // It holds unsaved text by any naive reading, and is STILL not dirty:
    // a projection has no file to write. Decided once, in
    // `Buffer.hasUnsavedFile`, not again here.
    try t.expectEqual(@as(i32, 0), dirtyOf(&id, b));
    try t.expectEqualStrings("git", toolOf(&id, b).?);
}

test {
    std.testing.refAllDecls(@This());
}
