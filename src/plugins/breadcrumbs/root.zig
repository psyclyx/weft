//! breadcrumbs — where the caret is, as a trail on the status line:
//! `path › outer › inner`, each crumb a symbol that encloses the caret.
//!
//! It is an ordinary status-line provider: it binds `ui/statusline-seg` for
//! text entries (the same slot the mode chip and the path answer), so it
//! sits right after the path and a click on a crumb runs the command the
//! crumb carries — `breadcrumbs-jump <offset>`, the symbol's start. No
//! header door, no knowledge of any language: the symbols are the grammar's
//! OUTLINE (`weft.outline`, the configured `outline.scm`), and "encloses"
//! is a span test.
//!
//! **Cheap on every frame.** This asks the outline only for the items
//! overlapping the caret's byte — the caret's path through the tree, never
//! the file. It used to read the WHOLE outline and cache it against the
//! document's snapshot witness; that made every keystroke re-run the outline query over the entire file (~15ms per
//! key on an 11.6k-line javascript file, the whole of a typing frame's cost),
//! and silently lost crumbs past its 512-symbol cap. It kept a private cache
//! too, which is gone: the host caches every status answer against the
//! caret and the SUBJECT's revision — its text and its tree
//! (`Context.revisionOf`) — so an idle redraw asks nothing, and a parse that
//! lands after the question was answered empty (a fresh file's first frames)
//! is a new question, asked again. The private cache could not know that:
//! it declined to cache an empty outline and relied on being asked every
//! frame, which the answer cache ended.
//! Nothing here ever asks a language server.

const std = @import("std");
const weft = @import("weft");
const statusline = @import("weft_statusline");

/// Only what encloses the caret is ever read, so this bounds nesting depth.
const max_symbols = 64;
const max_crumbs = 6;

const Symbol = struct { start: u32, end: u32, name_off: u32, name_len: u16 };

var symbols: [max_symbols]Symbol = undefined;
var symbol_count: usize = 0;
var names: [1 << 12]u8 = undefined;

fn init() void {
    // Text entries only (a listing's rows are not a document's symbols), at
    // the core tier so the crumbs fall in among the default segments — after
    // the path (80), before the link chip (70) — instead of ahead of them.
    statusline.bind(.{ .all = &.{ .{ .posture = "text" }, .{ .tool = "" } } }, .core, 75);
}

/// Read what encloses `caret`.
fn read(caret: u32) void {
    symbol_count = 0;
    const n = weft.outline(.{ .start = caret, .end = @as(usize, caret) + 1 });
    var used: usize = 0;
    var i: usize = 0;
    while (i < n and symbol_count < max_symbols) : (i += 1) {
        const c = weft.queryCapture(i) orelse continue;
        if (used + c.name.len > names.len) break;
        @memcpy(names[used..][0..c.name.len], c.name);
        symbols[symbol_count] = .{
            .start = @intCast(c.start),
            .end = @intCast(c.end),
            .name_off = @intCast(used),
            .name_len = @intCast(c.name.len),
        };
        used += c.name.len;
        symbol_count += 1;
    }
}

fn nameOf(s: Symbol) []const u8 {
    return names[s.name_off..][0..s.name_len];
}

var text_buf: [max_crumbs][96]u8 = undefined;
var command_buf: [max_crumbs][48]u8 = undefined;

fn on_slot_fire(session: i32) callconv(.c) void {
    const handle: u32 = @bitCast(session);
    const q = statusline.ask(handle) orelse return;
    // Only the focused pane's entry is the one the document doors read.
    if (!q.focused) return statusline.tell(handle, &.{});
    read(q.caret);
    var segs: [max_crumbs]statusline.Segment = undefined;
    var n: usize = 0;
    // Document order with nested items after their parents, so every
    // enclosing symbol comes out outermost first.
    for (symbols[0..symbol_count]) |s| {
        if (n >= max_crumbs) break;
        if (q.caret < s.start or q.caret >= s.end) continue;
        const text = std.fmt.bufPrint(&text_buf[n], " › {s}", .{nameOf(s)}) catch continue;
        const command = std.fmt.bufPrint(&command_buf[n], "breadcrumbs.jump {d}", .{s.start}) catch continue;
        segs[n] = .{ .text = text, .role = if (n == 0) .muted else .accent, .command = command };
        n += 1;
    }
    statusline.tell(handle, segs[0..n]);
}

/// `breadcrumbs-jump <offset>`: what a click on a crumb runs — the caret to
/// the symbol's start, leaving a jump behind.
fn jump() void {
    const arg = weft.argStr(0) orelse return;
    const offset = std.fmt.parseInt(usize, std.mem.trim(u8, arg, " "), 10) catch return;
    weft.jumpPush();
    weft.jump(offset);
}

const cmds = [_]weft.CommandEntry{
    .{ .name = "breadcrumbs.jump", .arity = .one, .call = jump, .params = "offset", .summary = "Move the cursor to a breadcrumb's symbol.", .internal = true },
};

comptime {
    weft.plugin(&cmds, .{ .init = init }).exportAll();
    weft.exportCallback("on_slot_fire", &on_slot_fire);
}
