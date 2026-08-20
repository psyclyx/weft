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

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

/// `yankRange(start, end, linewise)`: capture `[start, end)` of the active doc
/// into the register and snapshot the facts of every subbuffer it overlaps.
pub fn hYankRange(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const reg = p.register orelse return;
    const ed = p.ctx.editor();
    const rope = ed.text();
    const len = rope.byteLen();
    const s = @min(@as(usize, @intCast(args[0])), len);
    const e = @min(@as(usize, @intCast(args[1])), len);
    const linewise = args[2] != 0;
    const buf = p.gpa.alloc(u8, if (e > s) e - s else 0) catch return;
    defer p.gpa.free(buf);
    if (buf.len > 0) {
        var sr = rope.streamReader(.{ .start = s, .end = e }, &.{});
        sr.interface.readSliceAll(buf) catch return;
    }
    reg.yank(p.gpa, p.subbuffers, &ed.doc, .{ .start = s, .end = e }, buf, linewise) catch {};
}

/// `registerText(out_ptr, out_cap) -> len`: the register bytes into guest
/// memory (clamped to `cap`), for the editor to build its paste.
pub fn hRegisterText(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const reg = p.register orelse {
        results[0] = 0;
        return;
    };
    const n = caller.writeMemory(@intCast(args[0]), @intCast(args[1]), reg.slice()) catch 0;
    results[0] = @intCast(n);
}

/// `registerLinewise() -> bool`: whether the register holds a linewise yank.
pub fn hRegisterLinewise(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const reg = p.register orelse {
        results[0] = 0;
        return;
    };
    results[0] = @intFromBool(reg.linewise);
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
    const ed = p.ctx.editor();
    reg.restamp(p.gpa, subs, &ed.doc, @intCast(args[0]));
}
