// One status bar along the bottom of the window — a config FRAGMENT
// (`weft.use("statusbar")`).
//
// Like sidebar.js and toolbar.js, the bar is a composition, not a kind the
// workspace knows: a viewport presenting a designation (doc/model.md §2.4).
// A status line is the status segments of a context (doc/chrome.md §4.1);
// `weft://here/status/primary` is the PRIMARY context's — the editor's,
// never a docked companion's that has the keys — so the bar keeps describing
// the file you are working on while you click through the sidebar. What it
// shows is whatever the context's segments are: the place, git's branch, the
// problems counts, a running build on the left; the position, the language
// and the plugins' chips on the right. Each is published by what owns it.
//
// Use it LAST among the docked fragments: the viewport docked last is the
// outermost, so the bar spans the whole window, under the sidebar too.
weft.viewport("statusbar", {
  edge: "bottom",
  // No body rows: the pane is its status line, one row tall at any font
  // size, flush with the window's edges.
  extent: { rows: 0 },
  // Never in `window.focus-next`'s rotation, and never where the keys go: a
  // click on a segment acts in the context the bar describes.
  cycles: false,
  takesFocus: false,
  persistent: true,
  followFocus: false,
});

weft.present("statusbar", { subject: "weft://here/status/primary" });

// The bar says it once, so the panes do not say it again: no pane — the
// editor's, a split's, the sidebar's — carries a status line of its own.
weft.set("editor", "pane-status", "off");
