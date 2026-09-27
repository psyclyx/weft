// A toolbar docked along the top — a config FRAGMENT (`weft.use("toolbar")`).
//
// Like sidebar.js, "toolbar" is a named bundle of viewport attributes, not a
// kind the workspace knows, and no plugin owns it. It is a composition:
// viewport + subject + projection (doc/model.md §2.4). The subject is what the
// PRIMARY context offers, `weft://here/offers/primary`; the `offers` provider
// presents it as a strip of buttons — the pinned entries first
// (`weft.set("offers", "pinned", [...])`), then the context's offers grouped
// and ordered by their own presentation — and redraws it when those offers
// move. Presenting the same designation `as: "list"` in a docked column is a
// different line here, not a different plugin.
weft.plugin("offers");

weft.viewport("toolbar", {
  edge: "top",
  // One text row, however large the font: a share of the frame would grow
  // the strip with the window.
  extent: { rows: 1 },
  // Never in `window.focus-next`'s rotation, and never where the keys go: a click
  // acts through it and the editor keeps the keyboard, so the strip keeps
  // describing the editor while it is being clicked.
  cycles: false,
  takesFocus: false,
  // It owns its entry, and focus never lands here to be followed anyway.
  persistent: true,
  followFocus: false,
  // No room for a status line of its own in one row.
  statusLine: false,
});

weft.present("toolbar", { subject: "weft://here/offers/primary", as: "strip" });
