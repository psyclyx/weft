//! which-key — the menu-hint overlay, as a PLUGIN over the standard surface
//! door (perms `{}`). It is NOT special core rendering: core fires `on_menu` at
//! the frame boundary when a menu/prefix mode is entered or left, and this guest
//! reads that mode's AVAILABLE bindings (resolved through its fallback chain —
//! see Keymap.resolveBindings) and paints them into a retained corner popup —
//! the same door files/git use. A colorscheme restyles it for free (spans
//! carry a semantic Role, not a color): the KEY reads in the group/accent color
//! so it pops from the plain command text. When there are more bindings than fit
//! a page, it PAGINATES — `which-key.page-down`/`-up` (bound in `menu-nav`, which
//! menus fall back to) scroll it, and a footer shows the position.
//!
//! Every row reads by LABEL (doc/chrome.md §1.2): a leaf by its command's
//! (`Split Editor Right`, `Open File…`), a group by the name config gave it;
//! a command marked `internal` is keymap machinery and gets no row. A binding
//! whose arms name INTENTIONS does whatever the focused context offers, so
//! for those rows the hint asks the host's resolver the same question
//! dispatch asks (`weft.menuBindingIntent`) and shows the answer: `Tab
//! Expand/Collapse -> view` when it would run, the row dimmed with its reason
//! when it would not. Asking is a READ — it runs no provider and invokes
//! nothing.

const std = @import("std");
const weft = @import("weft");

/// Rows of bindings per page (before the position footer). A long menu — or a
/// mode's whole resolved set on an F1 peek — paginates instead of overflowing.
// Keep the guest's page generous and let the host viewport clamp the drawn
// rows. A fixed dozen rows made a large display look artificially sparse;
// pagination still applies on small windows because the renderer only has
// room for the rows that fit in the body.
const PAGE: usize = 32;
// Keep paging usable when the popup is clipped by a short pane. The renderer
// decides how many of PAGE rows fit, so advancing by a smaller stable step
// never jumps past content that is currently off-screen.
const PAGE_STEP: usize = 12;

/// The current page's first-binding offset (into the non-noise bindings). Reset
/// when a menu opens; advanced by the page commands.
var scroll_off: usize = 0;

const cmds = [_]weft.CommandEntry{
    .{ .name = "which-key.page-down", .arity = .whole, .call = pageDown, .summary = "Show the next page of key hints.", .internal = true },
    .{ .name = "which-key.page-up", .arity = .whole, .call = pageUp, .summary = "Show the previous page of key hints.", .internal = true },
};
comptime {
    weft.plugin(&cmds, .{}).exportAll();
}

/// Page down; `render` clamps to the last page.
fn pageDown() void {
    scroll_off += PAGE_STEP;
    render();
}
fn pageUp() void {
    scroll_off = if (scroll_off >= PAGE_STEP) scroll_off - PAGE_STEP else 0;
    render();
}

/// The baseline editing floor — self-insert + basic cursor/delete/newline. These
/// are the "regular keys" everyone knows; listing them in a which-key hint (an
/// F1 peek at a whole mode, or a mode that inherits the default editing keys) is
/// pure noise. (They never appear as CHORD completions — `completions(prefix)`
/// only offers keys that extend the pending chord — so this only trims the
/// whole-mode peek, exactly where the clutter is.)
fn isBaselineEdit(cmd: []const u8) bool {
    const floor = [_][]const u8{
        "edit.insert-text",  "edit.insert-newline", "edit.insert-tab", "edit.delete-before",
        "edit.delete-after", "cursor.left",         "cursor.right",    "cursor.up",
        "cursor.down",
    };
    for (floor) |c| if (std.mem.eql(u8, cmd, c)) return true;
    return false;
}

/// A menu's own leave/cancel/nav keys are noise in the hint popup — every
/// menu has them — and so is anything its command says is keymap machinery
/// (`internal`, doc/chrome.md §1.2: a mode's leave, the paging keys, a
/// grammar's count digits), and the baseline editing floor (see
/// `isBaselineEdit`). What is machinery is the command's to say, not a list
/// kept here.
fn isNoise(key: []const u8, cmd: []const u8, group: bool) bool {
    if (std.mem.eql(u8, key, "Escape") or std.mem.eql(u8, key, "C-g") or std.mem.eql(u8, key, "F1"))
        return true;
    if (group) return false;
    if (isBaselineEdit(cmd)) return true;
    const meta = weft.commandMeta(cmd) orelse return false;
    return meta.internal;
}

/// Drop the vocabulary prefix a provider's name doesn't need: `core.view`
/// reads as `view`. The full names stay the host's; this is presentation.
fn shortName(name: []const u8) []const u8 {
    for ([_][]const u8{ "std.", "core." }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return name[prefix.len..];
    }
    return name;
}

/// What a person reads for `name` — its label, with the prompt mark when it
/// asks for more (doc/chrome.md §1.2) — else the name itself.
fn labelOf(buf: []u8, name: []const u8) []const u8 {
    const meta = weft.commandMeta(name) orelse return shortName(name);
    return meta.shown(buf, shortName(name));
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
        if (!isNoise(weft.menuBindingKey(i), weft.menuBindingCmd(i), weft.menuBindingIsGroup(i))) total += 1;
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
    // Clamp the offset so the last page ends at the last row. Paging past the
    // end therefore STAYS at the end: clamping to a multiple of PAGE while
    // stepping by PAGE_STEP sent a short menu round a cycle (0, 12, 0, …),
    // which a reader paging until nothing changes never left.
    scroll_off = @min(scroll_off, if (total > PAGE) total - PAGE else 0);

    weft.surfaceBegin(placement());
    var idx: usize = 0; // index among non-noise bindings
    var shown: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = weft.menuBindingKey(i);
        const cmd = weft.menuBindingCmd(i);
        const group = weft.menuBindingIsGroup(i);
        if (isNoise(key, cmd, group)) continue;
        defer idx += 1;
        if (idx < scroll_off) continue;
        if (shown >= PAGE) break;
        weft.surfaceRow();
        var label_buf: [128]u8 = undefined;
        if (weft.menuBindingIntent(i)) |it| {
            // An intention binding does whatever the focused context offers:
            // paint what the resolver answers, by its LABEL — "Save -> git"
            // when it would run, the whole row dimmed with its reason when it
            // would not.
            weft.surfaceSpan(key, if (it.ready) .accent else .muted);
            weft.surfaceSpan(labelOf(&label_buf, it.name), if (it.ready) .leaf else .muted);
            if (it.ready) weft.surfaceSpan("->", .muted);
            if (it.note.len > 0) weft.surfaceSpan(shortName(it.note), .muted);
        } else {
            weft.surfaceSpan(key, .accent); // the key always stands out
            // A group is named by the config (`weft.group`); a leaf by its
            // command's label, which is what a person reads for it everywhere.
            weft.surfaceSpan(if (group) cmd else labelOf(&label_buf, cmd), if (group) .group else .leaf);
        }
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
fn on_menu(open: u32) callconv(.c) void {
    if (open == 0) {
        weft.surfaceClose();
        return;
    }
    scroll_off = 0; // a fresh menu starts at the top
    render();
}

comptime {
    weft.exportCallback("on_menu", &on_menu);
}
