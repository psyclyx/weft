//! which-key — the menu-hint overlay, as a PLUGIN over the standard surface
//! door (perms `{}`). It is NOT special core rendering: core fires `on_menu` at
//! the frame boundary when a menu/prefix mode is entered or left, and this guest
//! reads that mode's bindings and paints them into a retained corner popup — the
//! same door dired/magit use. A colorscheme restyles it for free (spans carry a
//! semantic Role, not a color): the KEY reads in the group/accent color so it
//! pops from the plain command text, the user's "color-code it" ask. The corner
//! placement is the "popup in the corner" layout the user preferred over a
//! full-width vertical stack.

const weft = @import("weft.zig");

export fn describe() void {}
export fn init() void {}

/// Core fires this when a menu mode is entered (open=1) or left (open=0). On
/// open, the current mode IS the menu, so we enumerate its bindings directly.
export fn on_menu(open: u32) void {
    if (open == 0) {
        weft.surfaceClose();
        return;
    }
    const n = weft.menuBindingCount();
    if (n == 0) {
        weft.surfaceClose();
        return;
    }
    weft.surfaceBegin(.corner);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = weft.menuBindingKey(i);
        const cmd = weft.menuBindingCmd(i);
        weft.surfaceRow();
        weft.surfaceSpan(key, .group); // the key stands out (accent)
        weft.surfaceSpan(cmd, .leaf); // the command in the plain color
    }
    weft.surfaceEnd(-1);
}
