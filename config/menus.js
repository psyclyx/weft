// Where core's commands sit in the menus — a config FRAGMENT
// (`weft.use("menus")`), used beside menubar.js (ide.js does), doc/chrome.md §2.
//
// Core says what a command IS — its label, summary, icon, whether it asks
// for more — and never where it lives: a menu path is placement, and
// placement is config. So a config that reshapes or renames the menus
// (`weft.set("menu", "menus", [...])`) replaces this file, or edits a line of
// it, instead of overriding core's commands one by one. A plugin still places
// its OWN commands (its `menu` presentation); a line here moves one of those
// too, since the config tier wins field by field.
//
// Each line is `weft.command(id, {menu, group, order})`: the menu path, the
// group that rules it off from its neighbours (menu.zig's default group
// order per menu), and its place in that group. Commands the windowed app
// alone registers (text size, permissions, identity, reload) are placed here
// too; a headless editor simply has no such row.

// ── File ─────────────────────────────────────────────────────────────
weft.command("file.open", { menu: "File", group: "open", order: 5 });
weft.command("file.browse-remote", { menu: "File", group: "open", order: 60 });
weft.command("file.save", { menu: "File", group: "save", order: 10 });
weft.command("file.save-as", { menu: "File", group: "save", order: 20 });
weft.command("buffer.close", { menu: "File", group: "close", order: 10 });
weft.command("buffer.close-force", { menu: "File", group: "close", order: 20 });
weft.command("app.reload-config", { menu: "File", group: "preferences", order: 10 });
weft.command("app.quit", { menu: "File", group: "exit", order: 10 });
weft.command("app.quit-force", { menu: "File", group: "exit", order: 11 });

// File ▸ Share: collaboration.
weft.command("collab.connect", { menu: "File/Share", group: "session", order: 10 });
weft.command("collab.cancel", { menu: "File/Share", group: "session", order: 15 });
weft.command("collab.listen", { menu: "File/Share", group: "session", order: 20 });
weft.command("collab.stop-listening", { menu: "File/Share", group: "session", order: 25 });
weft.command("collab.disconnect", { menu: "File/Share", group: "session", order: 30 });
weft.command("collab.share", { menu: "File/Share", group: "share", order: 10 });
weft.command("collab.share-presence", { menu: "File/Share", group: "share", order: 20 });
weft.command("collab.share-fs", { menu: "File/Share", group: "share", order: 30 });
weft.command("collab.peer-files", { menu: "File/Share", group: "files", order: 10 });
weft.command("collab.open-shared", { menu: "File/Share", group: "files", order: 20 });
weft.command("collab.realize-all", { menu: "File/Share", group: "files", order: 30 });
weft.command("collab.peers", { menu: "File/Share", group: "peers", order: 10 });
weft.command("collab.verify-peer", { menu: "File/Share", group: "peers", order: 20 });
weft.command("collab.forget-peer", { menu: "File/Share", group: "peers", order: 30 });
weft.command("collab.grant", { menu: "File/Share", group: "peers", order: 40 });

// ── Edit ─────────────────────────────────────────────────────────────
weft.command("edit.undo", { menu: "Edit", group: "history", order: 10 });
weft.command("edit.redo", { menu: "Edit", group: "history", order: 20 });
weft.command("edit.repeat", { menu: "Edit", group: "history", order: 30 });
weft.command("selection.cut", { menu: "Edit", group: "clipboard", order: 10 });
weft.command("selection.copy", { menu: "Edit", group: "clipboard", order: 20 });
weft.command("selection.paste-after", { menu: "Edit", group: "clipboard", order: 30 });
weft.command("selection.delete", { menu: "Edit", group: "clipboard", order: 50 });
weft.command("macro.record-start", { menu: "Edit/Macros", group: "record", order: 10 });
weft.command("macro.record-stop", { menu: "Edit/Macros", group: "record", order: 20 });
weft.command("macro.record-toggle", { menu: "Edit/Macros", group: "record", order: 30 });
weft.command("macro.play", { menu: "Edit/Macros", group: "play", order: 10 });

// ── View ─────────────────────────────────────────────────────────────
weft.command("theme.cycle-chrome", { menu: "View/Appearance", group: "chrome", order: 10 });
weft.command("theme.set-chrome", { menu: "View/Appearance", group: "chrome", order: 20 });
weft.command("theme.chrome-text", { menu: "View/Appearance/Chrome Style", group: "style", order: 1 });
weft.command("theme.chrome-text-icons", { menu: "View/Appearance/Chrome Style", group: "style", order: 2 });
weft.command("theme.chrome-widget", { menu: "View/Appearance/Chrome Style", group: "style", order: 3 });
weft.command("font.increase", { menu: "View/Appearance", group: "zoom", order: 10 });
weft.command("font.decrease", { menu: "View/Appearance", group: "zoom", order: 20 });
weft.command("font.reset", { menu: "View/Appearance", group: "zoom", order: 30 });
weft.command("font.set-size", { menu: "View/Appearance", group: "zoom", order: 40 });
weft.command("window.split-right", { menu: "View/Editor Layout", group: "split", order: 10 });
weft.command("window.split-below", { menu: "View/Editor Layout", group: "split", order: 20 });
weft.command("window.close", { menu: "View/Editor Layout", group: "split", order: 30 });
weft.command("window.focus-left", { menu: "View/Editor Layout", group: "focus", order: 10 });
weft.command("window.focus-right", { menu: "View/Editor Layout", group: "focus", order: 20 });
weft.command("window.focus-up", { menu: "View/Editor Layout", group: "focus", order: 30 });
weft.command("window.focus-down", { menu: "View/Editor Layout", group: "focus", order: 40 });
weft.command("window.focus-next", { menu: "View/Editor Layout", group: "focus", order: 50 });
weft.command("window.move-left", { menu: "View/Editor Layout", group: "move", order: 10 });
weft.command("window.move-right", { menu: "View/Editor Layout", group: "move", order: 20 });
weft.command("window.move-up", { menu: "View/Editor Layout", group: "move", order: 30 });
weft.command("window.move-down", { menu: "View/Editor Layout", group: "move", order: 40 });

// ── Go ───────────────────────────────────────────────────────────────
weft.command("jump.back", { menu: "Go", group: "history", order: 10 });
weft.command("jump.forward", { menu: "Go", group: "history", order: 20 });
weft.command("jump.pick", { menu: "Go", group: "history", order: 30 });
weft.command("buffer.next", { menu: "Go", group: "buffers", order: 10 });
weft.command("buffer.prev", { menu: "Go", group: "buffers", order: 20 });
weft.command("buffer.back", { menu: "Go", group: "buffers", order: 30 });
weft.command("jump.line", { menu: "Go", group: "line", order: 1 });

// ── Help ─────────────────────────────────────────────────────────────
weft.command("which-key.show", { menu: "Help", group: "keys", order: 10 });
weft.command("action.explain", { menu: "Help", group: "keys", order: 20 });
weft.command("grants.show", { menu: "Help", group: "permissions", order: 10 });
weft.command("grants.revoke", { menu: "Help", group: "permissions", order: 20 });
weft.command("app.identity", { menu: "Help", group: "permissions", order: 30 });
