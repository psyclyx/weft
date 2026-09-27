//! `wl_clipboard_set` / `wl_clipboard_get` — the system clipboard, for a guest
//! (doc/configs.md §3.3). One body each, shared with the JS plane
//! (`qjs_clipboard_*`), like the edit reads.
//!
//! Gated on `clipboard`, and the gate is CONFIG-ONLY (`plugin.zig`'s
//! `Perm.configOnly`): declaring it in `describe()` grants nothing. Reading
//! the clipboard reads whatever the user last copied anywhere on the desktop —
//! a password, a token — so no plugin gets it by asking; a config names who
//! may (`weft.grant("vim", "clipboard")`). Writing is gated with it: a plugin
//! that could silently replace what the user is about to paste into a shell is
//! as dangerous as one that reads it.
//!
//! The clipboard is the dispatching HEAD's (`Head.clipboard`) — a head is a
//! platform attachment, and the clipboard is the platform's. A read answers
//! the text the platform last received, synchronously: the platform reads a
//! foreign offer off the frame loop as soon as it is announced, so there is
//! nothing for a guest to wait on.

const std = @import("std");
const wasm = @import("../wasm.zig");
const shared = @import("plugin.zig");
const Door = @import("../plugin_resources.zig").Door;

/// `clipboardSet(ptr, len) -> 0 | -1`: take the clipboard with the guest's
/// bytes. -1 when they cannot be read or stored.
pub fn setBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const gpa = d.ctx.gpa;
    const bytes = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(bytes);
    d.ctx.head.clipboard.set(gpa, bytes) catch {
        results[0] = -1;
        return;
    };
    results[0] = 0;
}
pub const hClipboardSet = shared.wasmDoor(setBody, .clipboard);

/// `clipboardGet(out_ptr, out_cap) -> len`: the clipboard's text into guest
/// memory, clamped to `cap`. Returns the FULL length, so a guest whose buffer
/// was too small can tell and ask again with a bigger one.
pub fn getBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const text = d.ctx.head.clipboard.text();
    const cap: usize = @intCast(@max(args[1], 0));
    _ = caller.writeMemory(@intCast(args[0]), cap, text) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(@min(text.len, @as(usize, std.math.maxInt(i32))));
}
pub const hClipboardGet = shared.wasmDoor(getBody, .clipboard);
