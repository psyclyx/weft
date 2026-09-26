// A toolbar docked along the top — a config FRAGMENT (`weft.use("toolbar")`).
//
// Like sidebar.js, "toolbar" is a named bundle of viewport attributes, not a
// kind the workspace knows. The strip itself is the `toolbar` plugin: the
// primary context's offers, plus whatever `weft.set("toolbar", "pinned",
// [...])` pins, as a row of buttons that redraws when those offers change.
weft.plugin("toolbar");

weft.viewport("toolbar", {
  edge: "top",
  // One text row, however large the font: a share of the frame would grow
  // the strip with the window.
  extent: { rows: 1 },
  // Never in `focus-other`'s rotation, and never where the keys go: a click
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

// Its entry has no path to `open`; the plugin's own command presents it.
weft.present("toolbar", { command: "toolbar-open" });
