//! which-key — the menu-hint overlay, as a PLUGIN over the standard surface
//! door (perms `{}`). It is NOT special core rendering: core fires `on_menu` at
//! the frame boundary when a menu/prefix mode is entered or left, and this guest
//! reads that mode's AVAILABLE bindings (resolved through its fallback chain —
//! see Keymap.resolveBindings) and paints them into a retained corner popup —
//! the same door dired/magit use. A colorscheme restyles it for free (spans
//! carry a semantic Role, not a color): the KEY reads in the group/accent color
//! so it pops from the plain command text. When there are more bindings than fit
//! a page, it PAGINATES — `which-key-page-down`/`-up` (bound in `menu-nav`, which
//! menus fall back to) scroll it, and a footer shows the position.

const std = @import("std");
const weft = @import("weft.zig");

/// Rows of bindings per page (before the position footer). A long menu — or a
/// mode's whole resolved set on an F1 peek — paginates instead of overflowing.
const PAGE: usize = 12;

/// The current page's first-binding offset (into the non-noise bindings). Reset
/// when a menu opens; advanced by the page commands.
var scroll_off: usize = 0;

const cmds = [_][]const u8{ "which-key-page-down", "which-key-page-up" };

/// The baseline editing floor — self-insert + basic cursor/delete/newline. These
/// are the "regular keys" everyone knows; listing them in a which-key hint (an
/// F1 peek at a whole mode, or a mode that inherits the default editing keys) is
/// pure noise. (They never appear as CHORD completions — `completions(prefix)`
/// only offers keys that extend the pending chord — so this only trims the
/// whole-mode peek, exactly where the clutter is.)
fn isBaselineEdit(cmd: []const u8) bool {
    const floor = [_][]const u8{
        "insert-text",    "insert-newline", "insert-tab",   "delete-backward",
        "delete-forward", "cursor-left",    "cursor-right", "cursor-up",
        "cursor-down",
    };
    for (floor) |c| if (std.mem.eql(u8, cmd, c)) return true;
    return false;
}

/// A menu's own leave/cancel/nav bindings are noise in the hint popup — every
/// menu has them. Filter Escape/C-g/F1, the leave commands, the paging keys, and
/// the baseline editing floor (see `isBaselineEdit`).
fn isNoise(key: []const u8, cmd: []const u8) bool {
    return std.mem.eql(u8, key, "Escape") or std.mem.eql(u8, key, "C-g") or
        std.mem.eql(u8, key, "F1") or std.mem.eql(u8, cmd, "which-key-now") or
        std.mem.eql(u8, cmd, "menu-escape") or std.mem.eql(u8, cmd, "leader-cancel") or
        std.mem.eql(u8, cmd, "op-cancel") or
        std.mem.eql(u8, cmd, "which-key-page-down") or std.mem.eql(u8, cmd, "which-key-page-up") or
        isBaselineEdit(cmd);
}

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c);
}

/// Where the hint popup docks, from config: weft.set("which_key","placement",
/// "corner"|"center"). Corner (top-right) by default.
fn placement() weft.Placement {
    if (weft.configList("placement")) |list| {
        var it = list;
        if (it.next()) |p| {
            if (std.mem.eql(u8, p, "center")) return .center;
        }
    }
    return .corner;
}

/// Count the non-noise bindings available in the current mode.
fn countHints() usize {
    const n = weft.menuBindingCount();
    var total: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (!isNoise(weft.menuBindingKey(i), weft.menuBindingCmd(i))) total += 1;
    }
    return total;
}

/// Render the current page of hints into the surface.
fn render() void {
    const n = weft.menuBindingCount();
    const total = countHints();
    if (total == 0) {
        weft.surfaceClose();
        return;
    }
    // Clamp the offset to a valid page start (last page if it ran past the end).
    if (scroll_off >= total) scroll_off = (total - 1) / PAGE * PAGE;

    weft.surfaceBegin(placement());
    var idx: usize = 0; // index among non-noise bindings
    var shown: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = weft.menuBindingKey(i);
        const cmd = weft.menuBindingCmd(i);
        if (isNoise(key, cmd)) continue;
        defer idx += 1;
        if (idx < scroll_off) continue;
        if (shown >= PAGE) break;
        const group = weft.menuBindingIsGroup(i);
        weft.surfaceRow();
        weft.surfaceSpan(key, .accent); // the key always stands out
        weft.surfaceSpan(cmd, if (group) .group else .leaf); // group vs leaf color
        shown += 1;
    }
    // A position footer when it doesn't all fit — shows the range + that C-n/C-p
    // page it (and Backspace pops a level; the nav keys are `menu-nav` config).
    if (total > PAGE) {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{d}-{d}/{d}  C-n/C-p", .{ scroll_off + 1, scroll_off + shown, total }) catch "…";
        weft.surfaceRow();
        weft.surfaceSpan(msg, .muted);
    }
    weft.surfaceEnd(-1);
}

/// Core fires this when a menu mode is entered (open=1) or left (open=0). On
/// open, the current mode IS the menu; render its first page.
export fn on_menu(open: u32) void {
    if (open == 0) {
        weft.surfaceClose();
        return;
    }
    scroll_off = 0; // a fresh menu starts at the top
    render();
}

/// The paging commands re-render in place (the menu stays open; the command
/// doesn't change the mode). Ids match `cmds` registration order.
export fn on_command(id: u32) void {
    switch (id) {
        0 => scroll_off += PAGE, // page down (render clamps to the last page)
        1 => scroll_off = if (scroll_off >= PAGE) scroll_off - PAGE else 0, // page up
        else => return,
    }
    render();
}
