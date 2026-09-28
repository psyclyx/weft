// A menubar along the top — a config FRAGMENT (`weft.use("menubar")`),
// doc/chrome.md §2.
//
// Like toolbar.js, "menubar" is a named bundle of viewport attributes, not a
// kind the workspace knows: a viewport presenting the main menu,
// `weft://here/menu/main`, as a row of titles. What the menus hold is every
// command that says where it lives (its `menu` presentation: `View/Appearance`),
// in the conventional File, Edit, Selection, View, Go, Run, Terminal, Help —
// so a plugin loaded later files its commands into the same bar, and a config
// moves any of them with `weft.command(id, {menu, group, order})`. Core's own
// commands say no such thing: where they sit is config/menus.js, used here, so
// a config that reshapes the menus edits that file's lines. Each row
// shows the key that runs it in the editor, greys what cannot run there (its
// tooltip says why), and checks what it toggles. A chosen row runs in the
// PRIMARY context — the editor, even while a sidebar has the keys.
//
// It takes no focus: a click drops a menu down and the editor keeps the keys.
// F10 puts the keyboard on the bar (F10 again, or Escape, lets go), and Alt
// with a title's letter opens that menu; arrows, Enter, Escape and a row's
// letter work in it as in any desktop menu. Where no menubar is shown, F10
// opens the same menus at the caret.
//
// Declared ABOVE whatever else docks along the top: a fragment used after
// this one (a toolbar) sits beneath it.
weft.plugin("menu");
weft.use("menus");

weft.viewport("menubar", {
  edge: "top",
  extent: { rows: 1 },
  cycles: false,
  takesFocus: false,
  persistent: true,
  followFocus: false,
  statusLine: false,
});

weft.present("menubar", { subject: "weft://here/menu/main", as: "menubar" });

// The keys. `global`, so they reach every mode that has not claimed them.
weft.bind("global", "F10", "menu.focus-bar");
for (const title of ["file", "edit", "selection", "view", "go", "run", "terminal", "help"])
  weft.bind("global", "M-" + title[0], "menu.open-" + title);

// Rows that run a command WITH an argument (`Path\tLabel\tcommand arg\t
// toggle\tgroup\torder`): showing and hiding the bar itself. A config that
// composes more chrome lists its own (ide.js adds the toolbar's).
weft.set("menu", "items", [
  "View/Appearance\tMenu Bar\tviewport.toggle menubar\tviewport.menubar.shown\tviewports\t1",
]);
