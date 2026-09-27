//! textobjects — the text-object domain (design §6.1), a `.wasm` plugin with NO
//! core privilege (perms `{}`, view). Like motions, each returns a borrowed
//! live `range` an operator awaits (`di"`, `ca(`, `yiw`) — but the range
//! is absolute (the construct around the cursor), not cursor-anchored. Byte-scan
//! objects only for now; tree-backed objects (function/class) belong to the `ts`
//! plugin over `syntax.query`. `inner` excludes delimiters; `a` includes them
//! (and, for words, trailing whitespace).

const std = @import("std");
const weft = @import("weft");
/// The one word-character rule `\b` also uses.
const regex = @import("weft_regex");

const Obj = struct { s: usize, e: usize };
fn retObj(o: ?Obj) void {
    const x = o orelse return;
    if (weft.anchorRange(.{ .start = x.s, .end = x.e })) |h| weft.setResultRange(h);
}

// One command per (variant, object). Registration order == on_command id; the
// table is generated so vim can name `textobjects.inner-<obj>` / `textobjects.around-<obj>`.
const object_names = [_][]const u8{
    "word",       "big-word", "quote-double", "quote-single",
    "quote-back", "paren",    "bracket",      "brace",
    "paragraph",  "function", "class",        "call",
    "angle",      "pair",     "argument",     "comment",
    "test",
};
const cmds = blk: {
    var arr: [object_names.len * 2]weft.CommandEntry = undefined;
    var i: usize = 0;
    for (object_names) |obj| {
        arr[i] = .{ .name = "textobjects.inner-" ++ obj, .call = objHandler(obj, false), .arity = weft.Arity.each_extent };
        i += 1;
        arr[i] = .{ .name = "textobjects.around-" ++ obj, .call = objHandler(obj, true), .arity = weft.Arity.each_extent };
        i += 1;
    }
    break :blk arr;
};

fn objHandler(comptime obj: []const u8, comptime around: bool) fn () void {
    return struct {
        fn h() void {
            retObj(compute(obj, around));
        }
    }.h;
}

/// Dispatch a comptime object name to its scanner.
fn compute(comptime obj: []const u8, around: bool) ?Obj {
    if (comptime std.mem.eql(u8, obj, "word")) return wordObj(false, around);
    if (comptime std.mem.eql(u8, obj, "big-word")) return wordObj(true, around);
    if (comptime std.mem.eql(u8, obj, "quote-double")) return quoteObj('"', around);
    if (comptime std.mem.eql(u8, obj, "quote-single")) return quoteObj('\'', around);
    if (comptime std.mem.eql(u8, obj, "quote-back")) return quoteObj('`', around);
    if (comptime std.mem.eql(u8, obj, "paren")) return pairObj('(', ')', around);
    if (comptime std.mem.eql(u8, obj, "bracket")) return pairObj('[', ']', around);
    if (comptime std.mem.eql(u8, obj, "brace")) return pairObj('{', '}', around);
    if (comptime std.mem.eql(u8, obj, "angle")) return pairObj('<', '>', around);
    if (comptime std.mem.eql(u8, obj, "pair")) return closestPair(around);
    if (comptime std.mem.eql(u8, obj, "paragraph")) return paraObj(around);
    // Tree-backed objects (need a grammar; degrade to null without one). Both
    // inner and `a` return the enclosing node for now — precise inner bodies
    // want per-language modes. `around` is accepted but not yet distinguished.
    if (comptime std.mem.eql(u8, obj, "function")) return treeObj(&.{ "function", "fn_", "method" });
    if (comptime std.mem.eql(u8, obj, "class")) return treeObj(&.{ "class", "struct", "enum", "interface", "trait" });
    if (comptime std.mem.eql(u8, obj, "call")) return treeObj(&.{ "call", "invocation" });
    if (comptime std.mem.eql(u8, obj, "comment")) return treeObj(&.{"comment"});
    if (comptime std.mem.eql(u8, obj, "test")) return treeObj(&.{"test"});
    if (comptime std.mem.eql(u8, obj, "argument")) return argumentObj();
    return null;
}

/// The argument (or parameter) around the cursor: the node that sits
/// directly in an argument or parameter list, or a node that calls itself a
/// parameter. Grammar-agnostic by kind name, like `treeObj`.
fn argumentObj() ?Obj {
    const cur = weft.cursor();
    var node = weft.nodeEnclosing(.{ .start = cur, .end = cur }) orelse return null;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const self_param = std.mem.indexOf(u8, node.kind, "parameter") != null and !isList(node.kind);
        const here: Obj = .{ .s = node.start, .e = node.end };
        if (self_param) return here;
        const parent = weft.nodeEnclosing(.{ .start = here.s, .end = here.e }) orelse return null;
        if (isList(parent.kind)) return here;
        node = parent;
    }
    return null;
}

fn isList(kind: []const u8) bool {
    for ([_][]const u8{ "arguments", "parameters", "argument_list", "parameter_list" }) |k| {
        if (std.mem.indexOf(u8, kind, k) != null) return true;
    }
    return false;
}

/// The nearest pair of any kind around the cursor — brackets of every
/// shape, and quotes on its line: the innermost one wins.
fn closestPair(around: bool) ?Obj {
    const candidates = [_]?Obj{
        pairObj('(', ')', true), pairObj('[', ']', true), pairObj('{', '}', true),
        pairObj('<', '>', true), quoteObj('"', true),     quoteObj('\'', true),
        quoteObj('`', true),
    };
    var best: ?Obj = null;
    for (candidates) |c| {
        const o = c orelse continue;
        if (best) |b| if (o.s < b.s or (o.s == b.s and o.e >= b.e)) continue;
        best = o;
    }
    const o = best orelse return null;
    return if (around) o else .{ .s = o.s + 1, .e = o.e - 1 };
}

/// The nearest enclosing tree-sitter node whose KIND contains any needle
/// (grammar-agnostic), as a range. Null without a grammar / no match.
fn treeObj(comptime needles: []const []const u8) ?Obj {
    const cur = weft.cursor();
    var r = weft.Range{ .start = cur, .end = cur };
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const n = weft.nodeEnclosing(r) orelse return null;
        inline for (needles) |needle| {
            if (std.mem.indexOf(u8, n.kind, needle) != null) return .{ .s = n.start, .e = n.end };
        }
        r = .{ .start = n.start, .end = n.end };
    }
    return null;
}

// ── word classes (shared shape with the motions plugin) ───────────────
const Class = enum { space, word, punct };
fn classOf(b: u8) Class {
    if (b == ' ' or b == '\t' or b == '\n' or b == '\r') return .space;
    if (regex.isWordByte(b)) return .word;
    return .punct;
}
fn bigClass(b: u8) Class {
    return if (b == ' ' or b == '\t' or b == '\n' or b == '\r') .space else .word;
}

const window = 32000; // stays within the shim's read scratch

/// The word run containing the cursor; `around` extends over trailing space.
fn wordObj(big: bool, around: bool) ?Obj {
    const cur = weft.cursor();
    const len = weft.byteLen();
    const lo = cur -| window;
    const hi = @min(len, cur + window);
    const t = weft.slice(lo, hi);
    if (t.len == 0) return null;
    const cls: *const fn (u8) Class = if (big) bigClass else classOf;
    const rel = @min(cur - lo, t.len - 1);
    const c0 = cls(t[rel]);
    var s = rel;
    while (s > 0 and cls(t[s - 1]) == c0) s -= 1;
    var e = rel;
    while (e < t.len and cls(t[e]) == c0) e += 1; // exclusive
    if (around) while (e < t.len and cls(t[e]) == .space) {
        e += 1;
    };
    return .{ .s = lo + s, .e = lo + e };
}

/// The pair of `q` quotes on the current line surrounding the cursor.
fn quoteObj(q: u8, around: bool) ?Obj {
    const cur = weft.cursor();
    const l = weft.lineAt(cur);
    const t = weft.slice(l.start, l.end);
    const rel = cur - l.start;
    var open: ?usize = null;
    for (t, 0..) |c, i| {
        if (c != q) continue;
        if (open) |o| {
            if (rel >= o and rel <= i) {
                const s = l.start + o;
                const e = l.start + i;
                return if (around) .{ .s = s, .e = e + 1 } else .{ .s = s + 1, .e = e };
            }
            open = null;
        } else open = i;
    }
    return null;
}

/// The innermost `open`…`close` pair enclosing the cursor (nesting-aware).
fn pairObj(openc: u8, closec: u8, around: bool) ?Obj {
    const cur = weft.cursor();
    const len = weft.byteLen();
    const lo = cur -| window;
    const hi = @min(len, cur + window);
    const t = weft.slice(lo, hi);
    if (t.len == 0) return null;
    const rel = @min(cur - lo, t.len - 1);
    // Scan left for the enclosing open (a matched close on the way deepens).
    var depth: i32 = 0;
    var open_i: ?usize = null;
    var i: usize = rel;
    while (true) : (i -= 1) {
        const c = t[i];
        if (c == closec and i != rel) {
            depth += 1;
        } else if (c == openc) {
            if (depth == 0) {
                open_i = i;
                break;
            }
            depth -= 1;
        }
        if (i == 0) break;
    }
    const o = open_i orelse return null;
    // Scan right from just after the open for its match.
    depth = 0;
    var close_i: ?usize = null;
    var j = o + 1;
    while (j < t.len) : (j += 1) {
        const c = t[j];
        if (c == openc) {
            depth += 1;
        } else if (c == closec) {
            if (depth == 0) {
                close_i = j;
                break;
            }
            depth -= 1;
        }
    }
    const cl = close_i orelse return null;
    return if (around)
        .{ .s = lo + o, .e = lo + cl + 1 }
    else
        .{ .s = lo + o + 1, .e = lo + cl };
}

/// The paragraph (run of non-blank lines) containing the cursor; `around`
/// includes the trailing blank line.
fn paraObj(around: bool) ?Obj {
    const cur = weft.cursor();
    const len = weft.byteLen();
    const lo = cur -| window;
    const hi = @min(len, cur + window);
    const t = weft.slice(lo, hi);
    const rel = @min(cur - lo, if (t.len == 0) 0 else t.len - 1);
    // Blank line = a newline immediately followed by a newline (or an edge).
    var s = rel;
    while (s > 0) : (s -= 1) {
        if (t[s - 1] == '\n' and (s == 1 or t[s - 2] == '\n')) break;
    }
    var e = rel;
    while (e < t.len) : (e += 1) {
        if (t[e] == '\n' and (e + 1 >= t.len or t[e + 1] == '\n')) {
            e += 1; // include this newline
            break;
        }
    }
    if (around) while (e < t.len and t[e] == '\n') {
        e += 1;
    };
    return .{ .s = lo + s, .e = lo + e };
}

comptime {
    weft.plugin(&cmds, .{}).exportAll();
}
