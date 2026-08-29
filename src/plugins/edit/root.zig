//! edit — the edit domain's line operators, a `.wasm` plugin with NO core
//! privilege beyond the edit door (perms `{}`). `duplicate-line` copies the
//! current line and inserts the copy below it; `upcase-line` upper-cases it in
//! place as one undoable unit. Both read a read-only snapshot through
//! `lineAt`/`slice` and write through the gated `edit` door, authored as this
//! plugin's peer — a `view`-grade doc refuses inside the gate with zero
//! permission logic here.
//!
//! The smallest complete plugin in the reference set, and the shape every
//! other one repeats: `describe` declares the commands, `init` registers them,
//! `on_command` runs one. Read this one first.

const std = @import("std");
const weft = @import("weft");

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
