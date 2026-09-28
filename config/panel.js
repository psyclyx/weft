// A docked bottom panel — a config FRAGMENT (`weft.use("panel")`).
//
// Like the sidebar, "panel" is a named bundle of viewport attributes, not a
// kind the workspace knows. It shows ONE entry at a time: whatever a plugin
// last brought into it with core's `viewport.take` (the problems list, a
// terminal) — taking replaces, and hiding keeps the entry for when it is
// shown again. Nothing is presented at startup, so it starts hidden and
// opens on demand; `viewport.toggle panel` shows and hides it.
weft.viewport("panel", {
  edge: "bottom",
  // 12 rows TOTAL — header strip plus body — matching every other row-sized
  // viewport's `extent`: what you declare is what you get on screen.
  extent: { rows: 12 },
  // It owns its entry: an open from a problem row lands in the editor,
  // never in the panel.
  persistent: true,
  // Out of `window.focus-next`'s rotation, and not a primary-focus change: the
  // toolbar and the breadcrumbs keep describing the editor while you are
  // in the panel.
  cycles: false,
  followFocus: false,
  shown: false,
  // The header strip, like a VS Code / JetBrains docked panel. A command id
  // is one tab, labeled and iconed from its own metadata (`weft.command`) —
  // a click runs it. `entries:terminal` is, at that place, one tab per
  // entry the `terminal` plugin made that this panel has shown and that is
  // still open — every terminal — labeled by the entry (its title), a click
  // showing it here and its × closing it.
  tabs: ["problems.open", "entries:terminal", "terminal.new"],
});

// Which viewport each panel plugin takes — the name above.
weft.set("panel", "viewport", "panel");
weft.set("problems", "viewport", "panel");
weft.set("terminal", "viewport", "panel");
