//! Appending OUTPUT to a buffer by name: a console's command output, an
//! agent's streamed transcript — text produced below what is there, written
//! as a producer (`command.produceInto`), with an optional style class. One
//! body, bound on both planes (`wl_buffer_append`, `qjs_buffer_append`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("../command.zig");
const Door = @import("../plugin_resources.zig").Door;
const wasm = @import("../wasm.zig");

/// Who produced it, for a refusal's notice: output, not an author.
const transcript_peer = "agent-ui";

/// `bufferAppend(name, name_len, text, text_len, class)`: append `text` to
/// the end of the buffer named `name` (created if absent), painted with
/// style `class` (0 for none).
pub fn appendBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const gpa = d.resources.gpa;
    const name = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(name);
    const text = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(text);
    appendNamed(d.ctx, gpa, name, text, @truncate(@as(u32, @bitCast(args[4]))));
}

/// Append `text` to the end of the buffer named `name` (created if absent),
/// authored as a fixed tool peer — the streamed-transcript path, targeting a
/// buffer by name so it need not be focused (mirrors repl_session.drain).
pub fn appendNamed(ctx: *command.Context, gpa: Allocator, name: []const u8, text: []const u8, class: u8) void {
    const bufs = ctx.buffers;
    const b = bufs.get(bufs.ensureNamed(gpa, name) catch return) orelse return;
    const ed = b.textEditor() orelse return;
    const doc = &ed.doc;
    const start = ed.text().byteLen();
    command.produceInto(gpa, &ctx.buffers.notices, doc, .plugin, transcript_peer, &.{.{ .range = .{ .start = start, .end = start }, .bytes = text }}) catch return;
    if (class != 0) paintStyle(ctx, gpa, doc, start, start + text.len, class);
}

/// Paint `[start, end)` with StyleClass `class` on `doc`'s styles feed, growing
/// the class-per-byte bulk to the buffer's new length and PRESERVING prior
/// classes (so a streamed transcript keeps each chunk's color). The styles
/// layer is claimed once (find, else claim) and republished with the extended
/// array — the whole-buffer bulk the view paints from.
fn paintStyle(ctx: *command.Context, gpa: Allocator, doc: *@import("../Document.zig"), start: usize, end: usize, class: u8) void {
    const total = end; // the append put the new end here
    const layer = ctx.caps.layers.find(doc, "styles") orelse
        (ctx.caps.layers.claim(gpa, doc, "styles", .local, transcript_peer) catch return);
    const classes = gpa.alloc(u8, total) catch return;
    defer gpa.free(classes);
    @memset(classes, 0);
    if (layer.bulk) |b0| {
        const keep = @min(b0.classes.len, total);
        @memcpy(classes[0..keep], b0.classes[0..keep]);
    }
    const s = @min(start, total);
    @memset(classes[s..total], class);
    const version = doc.version(gpa) catch return;
    defer gpa.free(version);
    layer.publishBulk(gpa, version, 0, classes) catch {};
}
