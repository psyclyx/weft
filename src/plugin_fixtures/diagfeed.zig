//! Test fixture ONLY (not installed — see build.zig's `guests` table): a
//! diagnostics source in the shape the `problems` plugin reads, with no
//! language server behind it. A test drives it the way `lsp` is driven by a
//! server's publish:
//!
//!   - `diagfeed-set <rows>`: replace the rows (`path\tline\tcol\tseverity\t
//!     message`, newline-separated) and raise the `diagnostics` signal, as
//!     `lsp` does when a publish lands.
//!   - `diagfeed.list`: the rows, as the command's string result — what
//!     `weft.set("problems", "source", "diagfeed-list")` points the list at.

const weft = @import("weft");

var rows: [1 << 14]u8 = undefined;
var rows_len: usize = 0;

fn set() void {
    const s = weft.argStr(0) orelse "";
    const n = @min(s.len, rows.len);
    @memcpy(rows[0..n], s[0..n]);
    rows_len = n;
    weft.signalEmit("diagnostics");
}

fn list() void {
    weft.setResultStr(rows[0..rows_len]);
}

const cmds = [_]weft.CommandEntry{
    .{ .name = "diagfeed.set", .arity = .one, .call = set, .params = "rows" },
    .{ .name = "diagfeed.list", .arity = .one, .call = list },
};

comptime {
    weft.plugin(&cmds, .{}).exportAll();
}
