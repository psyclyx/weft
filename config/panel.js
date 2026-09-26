// A docked bottom panel — a config FRAGMENT (`weft.use("panel")`).
//
// Like the sidebar, "panel" is a named bundle of viewport attributes, not a
// kind the workspace knows. It shows ONE entry at a time: whatever a plugin
// last brought into it with core's `viewport-take` (the problems list, the
// terminal) — taking replaces, and hiding keeps the entry for when it is
// shown again. Nothing is presented at startup, so it starts hidden and
// opens on demand; `viewport-toggle panel` shows and hides it.
weft.viewport("panel", {
  edge: "bottom",
  extent: { rows: 12 },
  // It owns its entry: an open from a problem row lands in the editor,
  // never in the panel.
  persistent: true,
  // Out of `focus-other`'s rotation, and not a primary-focus change: the
  // toolbar and the breadcrumbs keep describing the editor while you are
  // in the panel.
  cycles: false,
  followFocus: false,
  shown: false,
});

// Which viewport each panel plugin takes — the name above.
weft.set("panel", "viewport", "panel");
weft.set("problems", "viewport", "panel");
weft.set("terminal", "viewport", "panel");
