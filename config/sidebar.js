// A docked files sidebar — a config FRAGMENT (`weft.use("sidebar")`).
//
// "Sidebar" is a named BUNDLE of viewport attributes, not a kind the
// workspace knows (doc/cwa-config-decisions.md D1). Every line here is
// manifest data: declarations the resolver and explain() read, with no
// interposing behavior anywhere — no hook in the keystroke path, no
// window-management code, no plugin of its own.
//
// The rows come from the generic tree presentation over whatever claims the
// subject, so slotting in document symbols or tree-sitter objects instead is
// a different `weft.present` line, not a different plugin.
weft.viewport("sidebar", {
  edge: "left",
  extent: 0.25,
  // Out of `focus-other`'s rotation: you reach it deliberately, never by
  // cycling past it.
  cycles: false,
  // It owns its entry — an open that lands elsewhere never drags it off its
  // root.
  persistent: true,
  // Focus landing here is not a primary-focus change, so companions that
  // follow the focus feed ignore it (and cannot chase themselves).
  followFocus: false,
});

// "Present resource R in viewport V" — an ordinary operation, declared. The
// subject opens through the same `open` every other locus runs.
weft.present("sidebar", { subject: "." });
