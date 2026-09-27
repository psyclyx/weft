//! panel — the one key a config binds to show and hide its bottom panel.
//!
//! A key names a command, never a command plus an argument, so the generic
//! `viewport-toggle <name>` needs a command that knows the name. This is it,
//! and all it is: `panel.toggle` toggles the viewport `weft.set("panel",
//! "viewport", …)` names (default `panel`, what `config/panel.js` declares).
//! Which entry the panel shows is the business of the plugins that take it
//! (`problems`, `terminal`).

const weft = @import("weft");

fn toggle() void {
    const name = weft.config("viewport");
    weft.runStr("viewport.toggle", if (name.len > 0) name else "panel");
}

const cmds = [_]weft.CommandEntry{
    .{ .name = "panel.toggle", .arity = .whole, .call = toggle, .summary = "Show or hide the bottom panel.", .label = "Panel", .menu = "View", .group = "panels", .order = 2, .icon = "panel-bottom", .toggle = "viewport.panel.shown" },
};

comptime {
    weft.plugin(&cmds, .{}).exportAll();
}
