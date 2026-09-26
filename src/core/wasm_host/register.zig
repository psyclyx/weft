//! The register/kill membrane: `yankRange` snapshots the yanked text + the
//! facts of any subbuffers it overlaps into the core register; `registerText`/
//! `registerLinewise` read it back (the editor keeps its own paste-positioning
//! policy); `pasteAt` re-stamps the ferried id-spans over text the editor has
//! ALREADY inserted at `base`. This is what makes a projection row's hidden
//! identity survive `dd`→`p` (a move) while a typed/raw-text line gets none (a
//! create) — see register.zig. Degrades honestly to a no-op when no register
//! service is wired.

const std = @import("std");
const wasm = @import("../wasm.zig");
const Register = @import("../register.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

fn slotArg(raw: i32) ?u8 {
    if (raw < 0 or raw > 26) return null;
    return @intCast(raw);
}

/// `yankRange(start, end, linewise)`: capture `[start, end)` of the active doc
/// into the register and snapshot the facts of every subbuffer it overlaps.
pub fn hYankRange(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const reg = p.register orelse return;
    const ed = (p.activeCtx().entry() orelse return).textEditor() orelse return;
    const rope = ed.text();
    const len = rope.byteLen();
    const s = @min(@as(usize, @intCast(args[0])), len);
    const e = @min(@as(usize, @intCast(args[1])), len);
    const linewise = args[2] != 0;
    const name = slotArg(args[3]) orelse return;
    const buf = p.gpa.alloc(u8, if (e > s) e - s else 0) catch return;
    defer p.gpa.free(buf);
    if (buf.len > 0) {
        var sr = rope.streamReader(.{ .start = s, .end = e }, &.{});
        sr.interface.readSliceAll(buf) catch return;
    }
    reg.yank(p.gpa, name, p.subbuffers, &ed.doc, .{ .start = s, .end = e }, buf, linewise) catch {};
}

/// `registerText(out_ptr, out_cap) -> len`: the register bytes into guest
/// memory (clamped to `cap`), for the editor to build its paste.
pub fn hRegisterText(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const reg = p.register orelse {
        results[0] = 0;
        return;
    };
    const slot = reg.get(slotArg(args[2]) orelse {
        results[0] = 0;
        return;
    }) orelse return;
    const n = caller.writeMemory(@intCast(args[0]), @intCast(args[1]), slot.slice()) catch 0;
    results[0] = @intCast(n);
}

/// `registerLinewise() -> bool`: whether the register holds a linewise yank.
pub fn hRegisterLinewise(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const reg = p.register orelse {
        results[0] = 0;
        return;
    };
    const slot = reg.get(slotArg(args[0]) orelse {
        results[0] = 0;
        return;
    }) orelse return;
    results[0] = @intFromBool(slot.linewise);
}

/// `pasteAt(base)`: re-claim a subbuffer for each ferried payload over the text
/// already inserted at `base`, restoring its facts. No-op without a subbuffer
/// service (nowhere to re-stamp) — the text still pastes; only identity is lost.
pub fn hPasteAt(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const reg = p.register orelse return;
    const subs = p.subbuffers orelse return;
    const ed = (p.activeCtx().entry() orelse return).textEditor() orelse return;
    const slot = reg.get(slotArg(args[1]) orelse return) orelse return;
    slot.restamp(p.gpa, subs, &ed.doc, @intCast(args[0]));
}

// ── One value per selection ──────────────────────────────────────────
// The multi-selection half of the same service: a grammar yanks every
// selection's range as its own value, and at paste time asks what selection
// `index` of `count` gets — core owns that answer (`Register.pasteSpan`: its
// own value when the counts match, else the joined text) so every grammar
// distributes the same way. Positioning stays the grammar's, as with
// `register_text`.

fn word(raw: i32) u32 {
    return @bitCast(raw);
}

/// `yankEach(ptr, n, linewise, name)`: capture the `n` `{start, end}` u32
/// pairs at `ptr` as one value each (in the order given — selection order),
/// snapshotting each value's subbuffer facts.
pub fn hYankEach(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const reg = p.register orelse return;
    const ed = (p.activeCtx().entry() orelse return).textEditor() orelse return;
    const n = word(args[1]);
    if (n == 0 or n > 1 << 16) return;
    const name = slotArg(args[3]) orelse return;
    const raw = caller.readMemory(p.gpa, word(args[0]), @as(usize, n) * 8) catch return;
    defer p.gpa.free(raw);
    const rope = ed.text();
    const len = rope.byteLen();
    const pieces = p.gpa.alloc(Register.Piece, n) catch return;
    defer p.gpa.free(pieces);
    var filled: usize = 0;
    defer for (pieces[0..filled]) |pc| p.gpa.free(pc.bytes);
    for (pieces, 0..) |*pc, i| {
        const s = @min(std.mem.readInt(u32, raw[8 * i ..][0..4], .little), len);
        const e = @max(s, @min(std.mem.readInt(u32, raw[8 * i + 4 ..][0..4], .little), len));
        const buf = p.gpa.alloc(u8, e - s) catch return;
        if (buf.len > 0) {
            var sr = rope.streamReader(.{ .start = s, .end = e }, &.{});
            sr.interface.readSliceAll(buf) catch {
                p.gpa.free(buf);
                return;
            };
        }
        pc.* = .{ .range = .{ .start = s, .end = e }, .bytes = buf };
        filled += 1;
    }
    reg.yankEach(p.gpa, name, p.subbuffers, &ed.doc, pieces, args[2] != 0) catch {};
}

/// `registerPasteValue(index, count, out_ptr, out_cap, name) -> len`: the
/// bytes selection `index` of `count` pastes, under the distribution rule.
pub fn hRegisterPasteValue(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const reg = p.register orelse return;
    const slot = reg.get(slotArg(args[4]) orelse return) orelse return;
    const bytes = slot.pasteValue(word(args[0]), word(args[1]));
    const n = caller.writeMemory(word(args[2]), word(args[3]), bytes) catch 0;
    results[0] = @intCast(n);
}

/// `pasteValueAt(base, index, count, name)`: `pasteAt` for the value
/// selection `index` of `count` pasted — only that value's identities.
pub fn hPasteValueAt(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const reg = p.register orelse return;
    const subs = p.subbuffers orelse return;
    const ed = (p.activeCtx().entry() orelse return).textEditor() orelse return;
    const slot = reg.get(slotArg(args[3]) orelse return) orelse return;
    slot.restampValue(p.gpa, subs, &ed.doc, word(args[0]), word(args[1]), word(args[2]));
}

test "register membrane accepts only canonical slots" {
    try std.testing.expectEqual(@as(?u8, 0), slotArg(0));
    try std.testing.expectEqual(@as(?u8, 26), slotArg(26));
    try std.testing.expectEqual(@as(?u8, null), slotArg(-1));
    try std.testing.expectEqual(@as(?u8, null), slotArg(27));
    try std.testing.expectEqual(@as(?u8, null), slotArg(std.math.maxInt(i32)));
}
