//! edit (wasm twin) — the edit-domain catalog plugin (src/core/catalog/edit.zig)
//! recompiled as a `.wasm` component. The SAME line operators — duplicate-line,
//! upcase-line — expressed against the guest ABI shim (weft.zig) instead of the
//! in-process `abi.Abi`. Byte-for-byte the same behavior; only the transport is
//! the sandbox membrane. This is plan 05's definition of done: a real catalog
//! plugin runs identically as `.wasm` under the perm handshake.

const std = @import("std");
const weft = @import("weft.zig");

/// Scratch for building an edit's bytes (no allocator in a freestanding guest).
var buf: [1 << 16]u8 = undefined;

var id_dup: u32 = 0;
var id_up: u32 = 0;

export fn describe() void {
    weft.declareCommand("duplicate-line");
    weft.declareCommand("upcase-line");
}

export fn init() void {
    id_dup = weft.register("duplicate-line");
    id_up = weft.register("upcase-line");
}

export fn on_command(id: u32) void {
    if (id == id_dup) duplicateLine() else if (id == id_up) upcaseLine();
}

/// Copy the current line and insert the copy right below it.
fn duplicateLine() void {
    const line = weft.lineAt(weft.cursor());
    const text = weft.slice(line.start, line.end); // borrows the shim scratch
    const n = @min(text.len, buf.len - 1);
    buf[0] = '\n'; // insert "\n<line>" at the line end → duplicate lands below
    @memcpy(buf[1 .. 1 + n], text[0..n]);
    weft.edit(.{ .start = line.end, .end = line.end }, buf[0 .. 1 + n]);
}

/// Upper-case the current line in place (one undoable unit).
fn upcaseLine() void {
    const line = weft.lineAt(weft.cursor());
    const text = weft.slice(line.start, line.end);
    const n = @min(text.len, buf.len);
    for (0..n) |i| buf[i] = std.ascii.toUpper(text[i]);
    weft.edit(.{ .start = line.start, .end = line.start + n }, buf[0..n]);
}
